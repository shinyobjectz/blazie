defmodule Blazie.Dispatch do
  @moduledoc """
  Run a brief on a machine that is not this one — fire-and-ack, write-back.

  The compute never has to live where the facts live. Socialite's harness
  proved the protocol shape the hard way: one microVM per task, the brief in
  the environment, no inbound path at all, everything after the ack arriving
  as writes the machine makes on its own — so a lost machine costs the run,
  never the transcript. This module is that shape with blazie's credential
  model attached: the machine writes back over the ordinary wire, presenting
  a token whose grant names EXACTLY the run's world, minted for the dispatch
  and revocable like any grant. What was asked and what came of it are facts
  under the run, so a vanished machine is a visible gap, not a mystery.

  ## The vendor seam

  Where the machine comes from is a behaviour — `launch/2` takes the brief
  and its environment and answers an id — so UpCloud today and Fly tomorrow
  are files, not words. `Blazie.Dispatch.Local` runs the brief in a process
  on this node, which is both the test vendor and the honest single-node
  answer: the protocol is identical, only the distance changes.

  ## What a brief may reach

  Nothing but the wire, as the world it was dispatched for. The token in the
  environment is granted one world before launch; the machine could present
  it anywhere and it names nothing else — tested by trying. That is the
  remit shape from the control plane meeting the fire-and-ack shape from the
  harness, and both halves already existed.
  """

  alias Blazie.{Authority, World}

  @type refusal :: %{problem: atom(), repair: String.t()}
  @type brief :: %{task: String.t(), world: World.name(), run: term()}

  @doc """
  Launch a brief. The environment carries everything the machine gets:
  the address to write back to, the token, the world, the run, the task.
  Answers an id for the record — the ack, after which everything arrives
  as writes.
  """
  @callback launch(brief(), env :: %{String.t() => String.t()}) ::
              {:ok, machine :: String.t()} | {:error, refusal()}

  @doc """
  Dispatch a task: mint the machine's credential, grant it the run's world
  and nothing else, and hand the brief to the vendor.

  Options: `vendor:` `{module, opts}` (the seam), `address:` where the
  machine writes back, `world:`/`run:`/`task:` the brief itself.
  """
  @spec run(keyword()) ::
          {:ok, %{machine: String.t(), token_fingerprint: String.t()}} | {:error, refusal()}
  def run(opts) do
    {vendor, vendor_opts} = Keyword.fetch!(opts, :vendor)
    world = Keyword.fetch!(opts, :world)
    run = Keyword.fetch!(opts, :run)
    task = Keyword.fetch!(opts, :task)
    address = Keyword.fetch!(opts, :address)

    # The machine's whole authority: one fresh token, one world. Minted per
    # dispatch so revoking it strands one machine and nothing else.
    token = "dispatch_" <> (:crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false))
    {:ok, _} = Authority.grant_checked(token, world)

    env = %{
      "BLAZIE_ADDRESS" => address,
      "BLAZIE_TOKEN" => token,
      "BLAZIE_WORLD" => to_string(world),
      "BLAZIE_RUN" => to_string(run),
      "BLAZIE_TASK" => task
    }

    # The vendor gets THE env — its own knobs ride in `vendor_opts`, and
    # nothing there may replace the credential wholesale.
    env = Map.merge(env, Keyword.get(vendor_opts, :extra_env, %{}))

    case vendor.launch(%{task: task, world: world, run: run}, env) do
      {:ok, machine} ->
        # The ack, on the record: the dispatch happened, whoever asks later.
        {:ok, _} =
          World.append(World.via(world), [
            {run, "dispatched_to", machine, run},
            {run, "dispatched_as", Authority.caller(token), run}
          ])

        {:ok, %{machine: machine, token_fingerprint: Authority.caller(token)}}

      {:error, refusal} ->
        {:error, refusal}
    end
  end

  @doc "The attributes a dispatch records itself with."
  @spec seed() :: [tuple()]
  def seed do
    Blazie.Attribute.define("dispatched_to", answers: "name", cardinality: "many") ++
      Blazie.Attribute.define("dispatched_as", answers: "name", cardinality: "many")
  end
end

defmodule Blazie.Dispatch.Local do
  @moduledoc """
  The vendor that is this node: the brief runs in a spawned process, talks
  back over the same wire a remote machine would, and can be killed the same
  way. The protocol is what the tests pin; the distance is the only thing a
  real vendor changes — which is the whole claim of the seam.
  """

  @behaviour Blazie.Dispatch

  @impl true
  def launch(_brief, env) do
    work = :persistent_term.get({__MODULE__, :work}, nil)

    if is_function(work, 1) do
      pid = spawn(fn -> work.(env) end)
      {:ok, "local-#{:erlang.pid_to_list(pid) |> to_string()}"}
    else
      {:error,
       %{
         problem: :no_work,
         repair:
           "The local vendor runs whatever `configure/1` was given — a function of the env " <>
             "map. Configure it, or dispatch to a vendor that owns real machines."
       }}
    end
  end

  @doc "What a launched brief does with its environment. The test's seam."
  @spec configure((%{String.t() => String.t()} -> term())) :: :ok
  def configure(work) when is_function(work, 1) do
    :persistent_term.put({__MODULE__, :work}, work)
  end
end
