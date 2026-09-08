import QtQuick

// Edge layer under the node cards. Draws one quadratic curve per edge from
// the right edge of `from` to the left edge of `to`. Repaints only when the
// graph, layout, or highlight state changes (never per-frame).
Canvas {
  id: root

  property var edges: []       // [{from,to,type}]
  property var positions: ({}) // id -> {x,y,w,h}
  property var highlightIds: ({}) // id -> true (empty = no highlight)
  property bool hasHighlight: false

  onEdgesChanged: requestPaint()
  onPositionsChanged: requestPaint()
  onHighlightIdsChanged: requestPaint()
  onHasHighlightChanged: requestPaint()

  function edgeColor(type) {
    if (type === "owns") return "#34D399";
    if (type === "selects") return "#22D3EE";
    if (type === "serves") return "#22D3EE";
    if (type === "routes-to") return "#FBBF24";
    if (type === "runs-on") return "#94A3B8";
    return "#475569";
  }

  onPaint: {
    var ctx = getContext("2d");
    ctx.clearRect(0, 0, width, height);
    ctx.lineWidth = 1.5;
    for (var i = 0; i < edges.length; i++) {
      var e = edges[i];
      var a = positions[e.from];
      var b = positions[e.to];
      if (!a || !b) continue;
      var active = !root.hasHighlight || (root.highlightIds[e.from] && root.highlightIds[e.to]);
      ctx.strokeStyle = edgeColor(e.type);
      ctx.globalAlpha = active ? 0.85 : 0.08;
      var x1 = a.x + a.w, y1 = a.y + a.h / 2;
      var x2 = b.x, y2 = b.y + b.h / 2;
      var mx = (x1 + x2) / 2;
      ctx.beginPath();
      ctx.moveTo(x1, y1);
      // Dashed for intent (selects/routes-to), solid for verified (serves/owns).
      if (e.type === "selects" || e.type === "routes-to") ctx.setLineDash([5, 4]);
      else ctx.setLineDash([]);
      ctx.bezierCurveTo(mx, y1, mx, y2, x2, y2);
      ctx.stroke();
      // Arrowhead.
      ctx.setLineDash([]);
      ctx.fillStyle = edgeColor(e.type);
      ctx.beginPath();
      ctx.moveTo(x2, y2);
      ctx.lineTo(x2 - 7, y2 - 3.5);
      ctx.lineTo(x2 - 7, y2 + 3.5);
      ctx.closePath();
      ctx.fill();
    }
    ctx.globalAlpha = 1.0;
  }
}
