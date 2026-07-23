defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/favicon.png", StaticAssetController, :favicon)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/operator-input", ObservabilityApiController, :operator_input)
    match(:*, "/api/v1/operator-input", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/review-decision", ObservabilityApiController, :review_decision)
    match(:*, "/api/v1/review-decision", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/memory/status", ObservabilityApiController, :memory_status)
    match(:*, "/api/v1/memory/status", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/memory/search", ObservabilityApiController, :memory_search)
    match(:*, "/api/v1/memory/search", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/memory/sessions/:session_id", ObservabilityApiController, :memory_session)
    match(:*, "/api/v1/memory/sessions/:session_id", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/audit", ObservabilityApiController, :audit_events)
    match(:*, "/api/v1/audit", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/audit/verify", ObservabilityApiController, :audit_verify)
    match(:*, "/api/v1/audit/verify", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/jobs", ObservabilityApiController, :jobs)
    match(:*, "/api/v1/jobs", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/jobs/:job_id/stop", ObservabilityApiController, :stop_job)
    match(:*, "/api/v1/jobs/:job_id/stop", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/waits", ObservabilityApiController, :waits)
    match(:*, "/api/v1/waits", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
