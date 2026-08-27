from fastapi import Request
from fastapi.templating import Jinja2Templates

templates = Jinja2Templates(directory="app/templates")


def render(request: Request, template_name: str, context: dict):
    """Render a fragment template (path relative to the templates dir, e.g.
    "partials/results_table.html" or "index.html") for htmx, or the same
    fragment wrapped in the page shell for a direct/non-htmx navigation
    (see htmx skill: branch response shape on the HX-Request header)."""
    context = {**context, "request": request}
    if request.headers.get("HX-Request"):
        return templates.TemplateResponse(template_name, context)
    fragment = templates.get_template(template_name).render(context)
    return templates.TemplateResponse("base.html", {**context, "content": fragment})


def render_error(request: Request, message: str, status_code: int = 200):
    """Error fragments are returned as 200 so they swap in htmx 2.x's
    default (non-2xx responses aren't auto-swapped) instead of vanishing."""
    return render(request, "partials/error.html", {"message": message})
