defmodule LazyRiver.Surface.ErrorJSON do
  @moduledoc "What a caller gets when nothing more specific applies."

  def render(template, _assigns) do
    %{"error" => %{"problem" => Phoenix.Controller.status_message_from_template(template)}}
  end
end
