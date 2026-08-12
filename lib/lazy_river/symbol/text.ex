defmodule LazyRiver.Symbol.Text do
  @moduledoc """
  Symbols for text, as a formula.

  `Symbol` enforces that a symbol is produced by a formula and never taken
  from outside, and that rule decides this module's whole shape. A hosted
  embedding model is a `Job` by definition — its answer happened once and
  cannot be reproduced — so a model behind an API can never write a symbol
  here. What can is an embedder that is DETERMINISTIC and runs in process:
  same text, same numbers, forever, and rebuildable from the ledger alone.

  That is not a limitation to work around. A symbol is a derived stand-in, and
  a stand-in you cannot re-derive is a number you have to trust. Making the
  derivation a formula is what keeps `Snapshot` a value: re-run the formula at
  the same snapshot and the same vectors come back.

  ## The seam

  `embed/1` is a plain function from text to a list of floats, so the embedder
  is chosen by the caller and this module never learns a model's name. A static
  embedder — a token table looked up and averaged, no matmul, no network — is
  the shape that fits: it is deterministic, it needs no GPU, and it is the only
  shape that could later run inside `Formula.Sandbox`, whose guest world is
  built from the imports the host hands in and which is handed none.

      formula =
        Symbol.Text.formula(:caption_symbols,
          over: "caption",
          into: "caption_symbol",
          space: "sketch_256",
          embed: &Symbol.Text.sketch(&1, 256)
        )

  ## Where the heavy models go

  X-CLIP, an OCR reader, a hosted text model: those are jobs, and what a job
  writes is a LITERAL. An OCR pass writes the words it read; a transcript job
  writes what was said. Those facts then feed this formula like any other text,
  which is why reading a frame and embedding a caption compose without either
  knowing about the other.
  """

  alias LazyRiver.{Attribute, Snapshot, Symbol}

  @doc """
  The attributes this formula needs, defined the ordinary way.

  The space is declared ON the attribute because `Symbol` refuses comparison
  across spaces — so the space has to be a fact about the attribute, not a
  convention in somebody's head.
  """
  @spec seed(String.t(), String.t()) :: [{String.t(), String.t(), term()}]
  def seed(into, space) when is_binary(into) and is_binary(space) do
    Symbol.seed() ++ Attribute.define(into, answers: "symbol", space: space)
  end

  @doc """
  A formula turning every text answer under `over` into a symbol under `into`.

  Options:

    * `:over`  — the attribute holding the text
    * `:into`  — the attribute the symbol is written to
    * `:space` — the space the symbol belongs to
    * `:embed` — text -> [float]; deterministic, or this is not a formula
  """
  @spec formula(term(), keyword()) :: LazyRiver.Formula.t()
  def formula(id, opts) do
    over = Keyword.fetch!(opts, :over)
    into = Keyword.fetch!(opts, :into)
    space = Keyword.fetch!(opts, :space)
    embed = Keyword.fetch!(opts, :embed)

    LazyRiver.Formula.new(id, fn snapshot ->
      snapshot
      |> Snapshot.find(attribute: over)
      |> Enum.flat_map(fn fact ->
        case fact.answer do
          text when is_binary(text) ->
            trimmed = String.trim(text)

            # Empty text is not a thing to represent. A symbol for "" is a real
            # point in the space that every empty answer would share, so the
            # nearest neighbour of one blank caption is every other blank one.
            if trimmed == "" do
              []
            else
              [{fact.id, into, Symbol.new(space, embed.(trimmed))}]
            end

          _ ->
            []
        end
      end)
    end)
  end

  @doc """
  A hashed sketch of the text — the dependency-free embedder.

  `Symbol` already counts a sketch as one of its kinds, and this is one: words
  are hashed into `width` buckets and the counts are the vector. It carries no
  weights, no download and no licence, and it is exactly deterministic, so it
  is the honest default for a formula that must be reproducible.

  IT IS NOT A SEMANTIC EMBEDDER, and the difference matters. It matches on
  shared words, so "ceramic pan" and "nonstick cookware" are far apart to it.
  Where meaning is the point, hand `:embed` a static token-table embedder
  instead — the seam takes any function of the same shape, and nothing else in
  this module changes.
  """
  @spec sketch(String.t(), pos_integer()) :: [float()]
  def sketch(text, width) when is_binary(text) and width > 0 do
    counts =
      text
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
      |> Enum.reduce(%{}, fn word, acc ->
        bucket = :erlang.phash2(word, width)
        # Signed by a second hash so that two different words landing in one
        # bucket can cancel rather than always reinforcing — a collision
        # should be noise, not a spurious similarity.
        sign = if :erlang.phash2({word, :sign}, 2) == 0, do: 1.0, else: -1.0
        Map.update(acc, bucket, sign, &(&1 + sign))
      end)

    vector = for i <- 0..(width - 1), do: Map.get(counts, i, 0.0)

    # Normalised here so cosine is a dot product downstream and a long caption
    # is not automatically "bigger" than a short one.
    norm = :math.sqrt(Enum.reduce(vector, 0.0, fn v, acc -> acc + v * v end))
    if norm > 0.0, do: Enum.map(vector, &(&1 / norm)), else: vector
  end
end
