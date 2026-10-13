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
const out = {
  top: root.name,
  order: rows.map((r) => r.name),
  folder: [rows[0].state, rows[0].level],
  folded: treeRows(root, levels, {'/extra': true}, '', 'name', false).map((r) => r.name),
  bySize: treeRows(root, levels, {}, '', 'size', true).filter((r) => !r.isDir && r.depth === 0).map((r) => r.name)[0],
  filtered: treeRows(root, levels, {}, 'a.t', 'name', false).map((r) => r.name),
  summary: treeSummary(files, levels),
  chosen: treeSetChosen(levels, ['2', '7'], true),
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
    check("the torrent's own top folder is dropped", out["top"] == "Pack")
    check("folders first, then files in natural order",
          out["order"] == ["extra", "a.txt", "b.txt", "Shot (1).jpg", "Shot (2).jpg",
                           "Shot (10).jpg", "Shot (11).jpg", "Shot (19).jpg"], str(out["order"]))
    check("a folder with differing priorities reads as mixed", out["folder"] == [2, -1], str(out["folder"]))
    check("a folded folder hides its files", out["folded"][:2] == ["extra", "Shot (1).jpg"], str(out["folded"]))
    check("sorting by size, biggest first", out["bySize"] == "Shot (19).jpg", out["bySize"])
    check("a filter keeps matching files and their folder", out["filtered"] == ["extra", "a.txt"], str(out["filtered"]))
    check("summary counts chosen files and bytes",
          out["summary"] == {"count": 7, "chosen": 6, "total": 4312, "selected": 4112}, str(out["summary"]))
    check("checking a file keeps its own priority, unchecked ones become normal",
          out["chosen"] == {"2": 1, "6": 3, "7": 1}, str(out["chosen"]))
    return summary()


if __name__ == "__main__":
    sys.exit(main())
