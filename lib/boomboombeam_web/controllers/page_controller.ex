defmodule BoomBoomBeamWeb.PageController do
  use BoomBoomBeamWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
