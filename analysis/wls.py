"""Query and charting helpers for the live sessions.

This module exists for one reason: in a live session the question arrives spoken
and the answer has to become a number and a chart in minutes. Everything that is
a styling decision — palette, axes, money formatting — is already settled here,
so the only thing left is the one thing that matters in the moment: writing the
right SQL.

    from analysis.wls import q, bar, stacked_bar, usd

    df = q("select partner, net_wls_revenue_cents from marts.mart_partner_performance")
    bar(df, x="net_wls_revenue_cents", y="partner", title="Net revenue by partner")

The connection is read-only: an open notebook doesn't hold DuckDB's write lock
and doesn't block a `python -m pipeline.run` running alongside it.
"""

from __future__ import annotations

from pathlib import Path

import duckdb
import pandas as pd
import plotly.graph_objects as go
import plotly.io as pio

PROJECT_ROOT = Path(__file__).resolve().parents[1]
DATABASE = PROJECT_ROOT / "data" / "duckdb" / "warehouse.duckdb"

# ---------------------------------------------------------------------------
# Palette
#
# Values taken unchanged from a validated reference palette, in its documented
# slot order — that order is what clears the colour-vision-deficiency separation
# thresholds (adjacent OKLab ΔE >= 8 in both modes). Reordering the slots or
# generating a ninth colour breaks that guarantee, so we do neither: past 8
# series, the tail folds into "Other".
# ---------------------------------------------------------------------------

LIGHT = {
    "surface": "#fcfcfb",
    "plane": "#f9f9f7",
    "ink": "#0b0b0b",
    "ink_secondary": "#52514e",
    "muted": "#898781",
    "grid": "#e1e0d9",
    "axis": "#c3c2b7",
    "series": ["#2a78d6", "#eb6834", "#1baf7a", "#eda100",
               "#e87ba4", "#008300", "#4a3aa7", "#e34948"],
    # Single-hue sequential ramp, light -> dark. For continuous magnitude.
    "ramp": ["#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5",
             "#256abf", "#184f95", "#0d366b"],
}

DARK = {
    "surface": "#1a1a19",
    "plane": "#0d0d0d",
    "ink": "#ffffff",
    "ink_secondary": "#c3c2b7",
    "muted": "#898781",
    "grid": "#2c2c2a",
    "axis": "#383835",
    # The same eight hues re-stepped for the dark surface — not an automatic
    # flip of the light set, but steps chosen for that band.
    "series": ["#3987e5", "#d95926", "#199e70", "#c98500",
               "#d55181", "#008300", "#9085e9", "#e66767"],
    "ramp": ["#0d366b", "#184f95", "#256abf", "#3987e5",
             "#6da7ec", "#9ec5f4", "#cde2fb"],
}

FONT = 'system-ui, -apple-system, "Segoe UI", sans-serif'

_mode = "light"


def tokens() -> dict:
    return LIGHT if _mode == "light" else DARK


def set_mode(mode: str) -> None:
    """Switch light/dark. Both are selected palettes, not inversions."""
    global _mode
    if mode not in ("light", "dark"):
        raise ValueError("mode must be 'light' or 'dark'")
    _mode = mode
    pio.templates.default = f"wls_{mode}"


def _build_template(t: dict) -> go.layout.Template:
    axis = dict(
        showgrid=True,
        gridcolor=t["grid"],
        gridwidth=1,
        zeroline=False,
        linecolor=t["axis"],
        linewidth=1,
        ticks="outside",
        ticklen=4,
        tickcolor=t["axis"],
        tickfont=dict(color=t["muted"], size=12),
        title=dict(font=dict(color=t["ink_secondary"], size=13)),
        automargin=True,
    )
    return go.layout.Template(
        layout=dict(
            paper_bgcolor=t["plane"],
            plot_bgcolor=t["surface"],
            colorway=t["series"],
            font=dict(family=FONT, color=t["ink"], size=13),
            title=dict(font=dict(size=17, color=t["ink"]), x=0, xanchor="left"),
            xaxis=axis,
            yaxis=axis,
            legend=dict(
                orientation="h", yanchor="bottom", y=1.0, xanchor="left", x=0,
                font=dict(color=t["ink_secondary"], size=12),
                bgcolor="rgba(0,0,0,0)",
            ),
            margin=dict(l=8, r=24, t=76, b=48),
            hoverlabel=dict(font=dict(family=FONT, size=12), bordercolor=t["axis"]),
            colorscale=dict(sequential=[[i / (len(t["ramp"]) - 1), c]
                                        for i, c in enumerate(t["ramp"])]),
        )
    )


pio.templates["wls_light"] = _build_template(LIGHT)
pio.templates["wls_dark"] = _build_template(DARK)
pio.templates.default = "wls_light"


# ---------------------------------------------------------------------------
# Querying
# ---------------------------------------------------------------------------

_connection: duckdb.DuckDBPyConnection | None = None


def connect() -> duckdb.DuckDBPyConnection:
    """Read-only connection, reused across calls."""
    global _connection
    if _connection is None:
        if not DATABASE.exists():
            raise FileNotFoundError(
                f"{DATABASE} does not exist. Run `python -m pipeline.run` first."
            )
        _connection = duckdb.connect(str(DATABASE), read_only=True)
    return _connection


def q(sql: str) -> pd.DataFrame:
    """Run SQL, return a DataFrame."""
    return connect().execute(sql).df()


def tables() -> pd.DataFrame:
    """What exists in the warehouse — the first command of every session."""
    return q("""
        select schema_name as schema, table_name as table, estimated_size as rows
        from duckdb_tables()
        where schema_name in ('marts', 'staging', 'intermediate', 'raw')
        order by case schema_name
            when 'marts' then 1 when 'intermediate' then 2
            when 'staging' then 3 else 4 end, table_name
    """)


def columns(table: str) -> pd.DataFrame:
    """Columns and types of a table. `columns('marts.fct_claim')`."""
    schema, _, name = table.rpartition(".")
    return q(f"""
        select column_name as column, data_type as type
        from information_schema.columns
        where table_name = '{name}'
          {f"and table_schema = '{schema}'" if schema else ""}
        order by ordinal_position
    """)


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

def usd(cents) -> str:
    """Integer cents -> dollar string. Compacts above $1k."""
    if cents is None or pd.isna(cents):
        return "—"
    value = float(cents) / 100
    if abs(value) >= 1_000_000:
        return f"${value / 1_000_000:,.1f}M"
    if abs(value) >= 1_000:
        return f"${value / 1_000:,.1f}k"
    return f"${value:,.2f}"


def pct(fraction, places: int = 1) -> str:
    if fraction is None or pd.isna(fraction):
        return "—"
    return f"{float(fraction) * 100:.{places}f}%"


# ---------------------------------------------------------------------------
# Charts
#
# Rules applied to all of them, so nobody has to remember them under pressure:
#
#   * thin marks, 4px rounded corner on the data end;
#   * 2px surface-coloured ring separating stacked segments;
#   * recessive grid and axes; text always in neutral ink, never in the series
#     colour — the coloured mark beside it carries the identity;
#   * direct labels on bars, and a legend whenever there are 2+ series, so
#     identity never depends on colour alone;
#   * tooltips on by default.
#
# One axis, always. Two measures on different scales become two charts — never a
# secondary axis.
# ---------------------------------------------------------------------------

BAR_CORNER = 4

# Below this share of the row, an inside label doesn't fit and Plotly rotates it
# into a scribble. In that case the label disappears and the value stays in the
# tooltip — that is what "selective direct labels" means in practice.
MIN_LABEL_SHARE = 0.07


def _title(title: str, note: str = "") -> dict:
    """Title with an optional subtitle — where the methodological caveat lives."""
    t = tokens()
    if not note:
        return dict(text=title, y=0.96, yanchor="top")
    subtitle = (
        "<br><span style='font-size:12px;font-weight:400;color:"
        + t["muted"] + "'>" + note + "</span>"
    )
    return dict(text=title + subtitle, y=0.96, yanchor="top")


def _top_margin(note: str, legend: bool) -> int:
    """Reserve room for title, subtitle and legend — in that order, no collision.

    Found by looking at the rendered chart: with a fixed margin, the legend rides
    over the second line of the title. The top is a function of what's in it, not
    a constant.
    """
    return 70 + (24 if note else 0) + (34 if legend else 0)


def _money_axis(fig: go.Figure, axis: str = "x") -> None:
    """Format a money axis.

    The warehouse stores integer cents. Plotting raw cents produces an axis that
    reads "7M" when the value is $70k — technically correct and completely
    misleading. Values are divided by 100 before plotting and the axis gets a
    currency prefix with an SI suffix.
    """
    update = fig.update_xaxes if axis == "x" else fig.update_yaxes
    update(tickprefix="$", tickformat="~s", separatethousands=True)


def bar(df: pd.DataFrame, x: str, y: str, title: str = "", *,
        money: bool = True, xtitle: str = "", note: str = "") -> go.Figure:
    """Horizontal bar sorted by magnitude. One series, single hue.

    Horizontal because the labels in this domain are long ("Iceberg Rx",
    "meridian"): rotating text on the x axis is the fastest way to make a chart
    unreadable.
    """
    t = tokens()
    data = df.sort_values(x)
    labels = [usd(v) if money else format(v, ",.0f") for v in data[x]]
    # Money is plotted in dollars; only the label comes from `usd()` on cents.
    values = data[x] / 100 if money else data[x]

    fig = go.Figure(go.Bar(
        x=values, y=data[y], orientation="h",
        marker=dict(color=t["series"][0], cornerradius=BAR_CORNER,
                    line=dict(color=t["surface"], width=1)),
        text=labels, textposition="outside",
        textfont=dict(color=t["ink_secondary"], size=12),
        customdata=labels,
        hovertemplate="<b>%{y}</b><br>" + (xtitle or x) + ": %{customdata}<extra></extra>",
    ))
    fig.update_layout(
        title=_title(title, note),
        xaxis_title=xtitle or None, yaxis_title=None,
        bargap=0.35, showlegend=False,
        margin=dict(l=8, r=24, t=_top_margin(note, legend=False), b=48),
        height=max(260, 46 * len(data) + 130),
    )
    # Headroom so the outside label on the longest bar isn't clipped.
    fig.update_xaxes(range=[0, float(values.max()) * 1.20])
    if money:
        _money_axis(fig)
    return fig


def stacked_bar(df: pd.DataFrame, y: str, series: dict, title: str = "", *,
                note: str = "", sort_by: str = "") -> go.Figure:
    """Part-to-whole per category. Stacked and horizontal.

    `series` maps column -> label, in stacking order. Colours come from the
    categorical slots in their documented order.
    """
    t = tokens()
    order = sort_by or list(series)[0]
    data = df.sort_values(order)
    row_totals = data[list(series)].sum(axis=1)

    fig = go.Figure()
    for index, (column, label) in enumerate(series.items()):
        labels = [usd(v) for v in data[column]]
        # Direct label only where it fits. In a narrow segment Plotly rotates the
        # text into a scribble — worse than having no label.
        shown = [text if share >= MIN_LABEL_SHARE else ""
                 for text, share in zip(labels, data[column] / row_totals)]
        fig.add_trace(go.Bar(
            x=data[column] / 100, y=data[y], orientation="h", name=label,
            marker=dict(color=t["series"][index],
                        line=dict(color=t["surface"], width=2)),
            text=shown, textposition="inside", insidetextanchor="middle",
            constraintext="none", cliponaxis=False,
            textfont=dict(color=t["surface"], size=11),
            customdata=labels,
            hovertemplate="<b>%{y}</b><br>" + label + ": %{customdata}<extra></extra>",
        ))

    fig.update_layout(
        title=_title(title, note), barmode="stack",
        barcornerradius=BAR_CORNER, bargap=0.35, yaxis_title=None,
        # Plotly reverses the legend on horizontal stacked bars. The legend has
        # to read in the same order the colours appear in the bar.
        legend_traceorder="normal",
        margin=dict(l=8, r=24, t=_top_margin(note, legend=True), b=48),
        height=max(300, 48 * len(data) + 170),
    )
    _money_axis(fig)
    return fig


def scatter(df: pd.DataFrame, x: str, y: str, title: str = "", *,
            log_x: bool = False, log_y: bool = False,
            money_x: bool = False, money_y: bool = False,
            xtitle: str = "", ytitle: str = "", note: str = "") -> go.Figure:
    """Single-series scatter. One hue, translucent marks.

    One series, so no legend: the title names what's on the chart.

    Expects values already in dollars — unlike `bar`, there is no cents
    conversion here, because a scatter usually crosses different units.
    """
    t = tokens()
    fig = go.Figure(go.Scattergl(
        x=df[x], y=df[y], mode="markers",
        marker=dict(size=5, color=t["series"][0], opacity=0.25, line=dict(width=0)),
        hovertemplate=(
            (xtitle or x) + ": %{x:,.2f}<br>" + (ytitle or y) + ": %{y:,.2f}<extra></extra>"
        ),
    ))
    fig.update_layout(title=_title(title, note), showlegend=False,
                      margin=dict(l=8, r=24, t=_top_margin(note, legend=False), b=56),
                      xaxis_title=xtitle or x, yaxis_title=ytitle or y, height=460)

    # On a log scale Plotly labels every minor tick by default (2, 5, 10, 2, 5,
    # 100...) and the axis turns into noise. `dtick=1` labels one decade at a
    # time and keeps the minor ticks as unlabelled marks.
    if log_x:
        fig.update_xaxes(type="log", dtick=1)
    if log_y:
        fig.update_yaxes(type="log", dtick=1)
    if money_x:
        fig.update_xaxes(tickprefix="$", tickformat="~s")
    if money_y:
        fig.update_yaxes(tickprefix="$", tickformat="~s")
    return fig


def heatmap(df: pd.DataFrame, x: str, y: str, z: str, title: str = "", *,
            note: str = "", money: bool = True) -> go.Figure:
    """Magnitude grid. Single-hue sequential ramp: more is darker."""
    t = tokens()
    grid = df.pivot(index=y, columns=x, values=z)
    text = grid.map(lambda v: usd(v) if money else
                    (format(v, ",.0f") if pd.notna(v) else "—"))
    # The colour scale has to speak the same language as the cell label. Plotting
    # raw cents would give a bar reading "1.5M" next to cells reading "$19.5k".
    values = grid / 100 if money else grid

    fig = go.Figure(go.Heatmap(
        x=list(grid.columns), y=list(grid.index), z=values.values,
        colorscale=[[i / (len(t["ramp"]) - 1), c] for i, c in enumerate(t["ramp"])],
        text=text.values, texttemplate="%{text}", textfont=dict(size=11),
        xgap=2, ygap=2,  # the 2px surface-coloured gap between cells
        hovertemplate="%{y} × %{x}<br>" + z + ": %{text}<extra></extra>",
        colorbar=dict(outlinewidth=0, thickness=10, len=0.7,
                      tickprefix="$" if money else "", tickformat="~s",
                      tickfont=dict(color=t["muted"], size=11)),
    ))
    fig.update_layout(title=_title(title, note), xaxis_title=None, yaxis_title=None,
                      margin=dict(l=8, r=24, t=_top_margin(note, legend=False), b=48),
                      height=max(300, 44 * len(grid) + 170))
    fig.update_xaxes(showgrid=False, ticks="")
    fig.update_yaxes(showgrid=False, ticks="")
    return fig


def line(df: pd.DataFrame, x: str, y: str, color: str = "", title: str = "", *,
         ytitle: str = "", note: str = "") -> go.Figure:
    """Time series.

    Refuses more series than the palette has slots. Generating a ninth colour is
    the quiet way to break colour-vision separation — better to fail here and
    fold the tail into "Other" than to publish an unreadable chart.
    """
    t = tokens()
    groups = list(df.groupby(color, sort=False)) if color else [("", df)]

    if len(groups) > len(t["series"]):
        raise ValueError(
            f"{len(groups)} series exceed the {len(t['series'])} palette slots. "
            "Fold the tail into 'Other' or use small multiples — generating a "
            "new colour breaks colour-vision separation."
        )

    fig = go.Figure()
    for index, (name, group) in enumerate(groups):
        group = group.sort_values(x)
        fig.add_trace(go.Scatter(
            x=group[x], y=group[y], mode="lines", name=str(name) if name else y,
            line=dict(color=t["series"][index], width=2),
        ))

    fig.update_layout(title=_title(title, note), xaxis_title=None,
                      yaxis_title=ytitle or y, hovermode="x unified",
                      margin=dict(l=8, r=24, t=_top_margin(note, legend=bool(color)), b=48),
                      height=420, showlegend=bool(color))
    return fig


def kpi(items: list, title: str = "") -> go.Figure:
    """A row of anchor numbers.

    A handful of headlines doesn't become a bar chart — it becomes stat tiles.
    It's the right form for "how many claims, how much revenue, what coverage".

    Built from annotations on a blank figure rather than `go.Indicator`. The
    Indicator sizes its title block for a single line at the title font size, so
    a two-line title carrying a 30px value drew the label straight through the
    digits. Annotations put the y position under our control, which is the whole
    requirement here.
    """
    t = tokens()
    fig = go.Figure()
    step = 1.0 / max(len(items), 1)

    for index, (label, value) in enumerate(items):
        x = index * step
        # Value above label, left-aligned: the eye lands on the number first,
        # and every tile shares a left edge with the title.
        fig.add_annotation(
            x=x, y=0.62, text=str(value), showarrow=False,
            xref="paper", yref="paper", xanchor="left", yanchor="middle",
            font=dict(size=30, color=t["ink"], weight="bold"),
        )
        fig.add_annotation(
            x=x, y=0.20, text=str(label), showarrow=False,
            xref="paper", yref="paper", xanchor="left", yanchor="middle",
            font=dict(size=12, color=t["muted"]),
        )

    # No data, so no axes: the tiles are text on a surface, not a plot.
    fig.update_xaxes(visible=False, range=[0, 1], fixedrange=True)
    fig.update_yaxes(visible=False, range=[0, 1], fixedrange=True)
    fig.update_layout(
        title=_title(title), height=175, margin=dict(l=8, r=8, t=66, b=8),
        # The template paints the plot area a shade off the surface. With no
        # plot to delimit, that shade reads as a card nobody asked for.
        plot_bgcolor="rgba(0,0,0,0)",
    )
    return fig
