"""The file tree is shared word for word by the extension and the DankBar plugin.

    python3 tests/test_filetree.py

Checks the two copies match, then runs the tree's own checks under Node.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from tests.harness import check, summary  # noqa: E402

EXTENSION = ROOT / "extension" / "lib" / "filetree-core.js"
PLUGIN = ROOT / "dms-plugin" / "lib" / "FileTree.js"

SCRIPT = r"""
const files = [1, 2, 10, 11, 19].map((n, i) => ({index: String(i + 1), path: `/dl/Pack/Shot (${n}).jpg`,
  length: n * 100, completedLength: n * 10}))
  .concat([{index: '6', path: '/dl/Pack/extra/b.txt', length: 5, completedLength: 5},
           {index: '7', path: '/dl/Pack/extra/a.txt', length: 7, completedLength: 0}]);
const root = treeBuild(files, '/dl');
const levels = {'2': 0, '6': 3};
const rows = treeRows(root, levels, {}, '', 'name', false);
const inner = rows.slice(1);
const out = {
  top: root.name,
  order: rows.map((r) => r.name),
  folder: [inner[0].state, inner[0].level],
  folderTotals: [inner[0].size, inner[0].wanted, inner[0].wantedDone],
  allSkipped: treeRows(root, {'6': 0, '7': 0}, {}, '', 'name', false)[1].level,
  sameLevel: treeRows(root, {'6': 2, '7': 2}, {}, '', 'name', false)[1].level,
  skipAndNormal: treeRows(root, {'6': 0}, {}, '', 'name', false)[1].level,
  folded: treeRows(root, levels, {'/Pack/extra': true}, '', 'name', false).map((r) => r.name),
  bySize: treeRows(root, levels, {}, '', 'size', true).filter((r) => !r.isDir && r.depth === 1).map((r) => r.name)[0],
  filtered: treeRows(root, levels, {}, 'a.t', 'name', false).map((r) => r.name),
  summary: treeSummary(files, levels),
  chosen: treeSetChosen(levels, ['2', '7'], true),
  pickOne: treePick(rows, {}, '', rows[1].key, false, false).picked,
  pickRange: Object.keys(treePick(rows, {[rows[1].key]: true}, rows[1].key, rows[3].key, true, false).picked).length,
  pickFolder: treePickedIndices(rows, {[rows[1].key]: true}).sort(),
};
console.log(JSON.stringify(out));
"""


def main() -> int:
    print("\nfile tree")
    check("the extension and the DankBar plugin carry the same file tree",
          EXTENSION.read_text(encoding="utf-8") == PLUGIN.read_text(encoding="utf-8"))
    if not shutil.which("node"):
        print("  (tree checks skipped: node is not installed)")
        return summary()
    import json
    result = subprocess.run(["node", "-e", EXTENSION.read_text(encoding="utf-8") + SCRIPT],
                            capture_output=True, text=True, check=True)
    out = json.loads(result.stdout)
    check("the torrent's own top folder is kept as a row", out["top"] == "Pack" and out["order"][0] == "Pack",
          str(out["order"][:2]))
    check("folders first, then files in natural order",
          out["order"] == ["Pack", "extra", "a.txt", "b.txt", "Shot (1).jpg", "Shot (2).jpg",
                           "Shot (10).jpg", "Shot (11).jpg", "Shot (19).jpg"], str(out["order"]))
    check("a folder with differing priorities reads as mixed", out["folder"] == [2, -1], str(out["folder"]))
    check("a folder counts all its bytes, the wanted ones, and what of those is done",
          out["folderTotals"] == [12, 12, 5], str(out["folderTotals"]))
    check("a folder whose files are all skipped reads as Skip", out["allSkipped"] == 0, str(out["allSkipped"]))
    check("files that agree give the folder their priority", out["sameLevel"] == 2, str(out["sameLevel"]))
    check("a skipped file beside a wanted one makes the folder Mixed", out["skipAndNormal"] == -1,
          str(out["skipAndNormal"]))
    check("a folded folder hides its files", out["folded"][:3] == ["Pack", "extra", "Shot (1).jpg"], str(out["folded"]))
    check("sorting by size, biggest first", out["bySize"] == "Shot (19).jpg", out["bySize"])
    check("a filter keeps matching files and their folders", out["filtered"] == ["Pack", "extra", "a.txt"],
          str(out["filtered"]))
    check("a click picks one row", list(out["pickOne"]) == ["/Pack/extra"], str(out["pickOne"]))
    check("Shift picks the range between", out["pickRange"] == 3, str(out["pickRange"]))
    check("a picked folder stands for every file inside it", out["pickFolder"] == ["6", "7"], str(out["pickFolder"]))
    check("summary counts chosen files and bytes",
          out["summary"] == {"count": 7, "chosen": 6, "total": 4312, "selected": 4112}, str(out["summary"]))
    check("checking a file keeps its own priority, unchecked ones become normal",
          out["chosen"] == {"2": 1, "6": 3, "7": 1}, str(out["chosen"]))
    return summary()


if __name__ == "__main__":
    sys.exit(main())
