.pragma library

// Layout constants that more than one surface has to agree on.

// DankFlickable and DankListView paint their scrollbar *over* their right edge
// rather than reserving a strip for it, so any content that reaches the edge
// ends up underneath it — a dropdown's chevron, a row's action buttons. Content
// stops this far short instead: the bar is 10px, the rest is air.
var SCROLLBAR_GUTTER = 14
