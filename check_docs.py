"""Check that the objon.md / docs/ split can't quietly rot.

Usage (from the project root):  python3 check_docs.py

Fails (exit 1) when:
  - objon.md has no "## Docs index" section;
  - the docs index names a docs/ file that does not exist;
  - a file under docs/ is not named in the docs index;
  - a docs/ file does not end with a "Reads with:" line, or that line names a .md file that does not exist;
  - any `x.md` named in backticks in objon.md or docs/ does not exist (a stale cross-reference).
Warns (exit code unaffected) when objon.md, the core every session reads, is over about 10k tokens
(characters / 4), a topic file is over about 12k, or a scene under scenes/interactive, traps, enemies or
collectibles is never named in docs/level-design.md (so a new object type nobody added to the designer's
reference shows up here). The check is a normalised substring match, so it is a nudge, not proof.
"""
import re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent
core = root / 'objon.md'
docs = root / 'docs'
CORE_BUDGET_TOKENS = 10000
TOPIC_BUDGET_TOKENS = 12000

errors, warnings = [], []
text = core.read_text(encoding='utf-8')
topic_files = sorted(docs.glob('*.md')) if docs.is_dir() else []
on_disk = {p.name for p in topic_files}
known = on_disk | {p.name for p in root.glob('*.md')}

m = re.search(r'^## Docs index[^\n]*\n(.*?)(?=^## |\Z)', text, re.S | re.M)
if not m:
    errors.append('objon.md has no "## Docs index" section')
    indexed = set()
else:
    indexed = set(re.findall(r'`docs/([\w\-]+\.md)`', m.group(1)))

for n in sorted(indexed - on_disk):
    errors.append('docs index names docs/%s, which does not exist' % n)
for n in sorted(on_disk - indexed):
    errors.append('docs/%s is not named in the docs index in objon.md' % n)

for p in topic_files:
    t = p.read_text(encoding='utf-8')
    nonblank = [l for l in t.split('\n') if l.strip()]
    last = nonblank[-1] if nonblank else ''
    if not last.startswith('Reads with:'):
        errors.append('docs/%s does not end with a "Reads with:" line' % p.name)
    else:
        for n in re.findall(r'`([\w\-./]+\.md)`', last):
            if n.split('/')[-1] not in known:
                errors.append('docs/%s: "Reads with:" names %s, which does not exist' % (p.name, n))
    if len(t) / 4 > TOPIC_BUDGET_TOKENS:
        warnings.append('docs/%s is about %dk tokens (budget %dk): consider splitting it' %
                        (p.name, len(t) // 4000, TOPIC_BUDGET_TOKENS // 1000))

# stale cross-references anywhere in the core or the topic files
for p in [core] + topic_files:
    t = p.read_text(encoding='utf-8')
    for n in sorted(set(re.findall(r'`([\w\-./]+\.md)`', t))):
        base = n.split('/')[-1]
        if base not in known:
            errors.append('%s names %s, which does not exist' % (p.relative_to(root), n))

# nudge: every placeable scene should be named in the designer's reference (docs/level-design.md)
DESIGN_REF = docs / 'level-design.md'
# scene file stem -> the word the reference uses; stems in SKIP are helpers a designer never places
DESIGN_ALIASES = {'gem_1': 'gem', 'gem_2': 'bonus gem', 'rail_with_bot': 'rail', 'conveyor_belt': 'conveyor'}
DESIGN_SKIP = {'bullet', 'arc', 'spark'}  # spawned by a turret, cannon or rail bot; covered under those entries
def _norm(t):
    return re.sub(r'[^a-z0-9]', '', t.lower())
if DESIGN_REF.is_file():
    ref_text = _norm(DESIGN_REF.read_text(encoding='utf-8'))
    for sub in ('interactive', 'traps', 'enemies', 'collectibles'):
        for scene in sorted((root / 'scenes' / sub).rglob('*.tscn')):
            stem = scene.stem
            if stem in DESIGN_SKIP:
                continue
            if _norm(DESIGN_ALIASES.get(stem, stem)) not in ref_text:
                warnings.append('scenes/%s/%s is not named in docs/level-design.md: add its catalogue entry' %
                                (sub, scene.name))

if len(text) / 4 > CORE_BUDGET_TOKENS:
    warnings.append('objon.md is about %dk tokens (budget %dk): move something into a topic file' %
                    (len(text) // 4000, CORE_BUDGET_TOKENS // 1000))

print('objon.md (core): ~%dk tokens' % (len(text) // 4000))
for p in topic_files:
    print('docs/%-24s ~%dk tokens' % (p.name, len(p.read_text(encoding='utf-8')) // 4000))
for w in warnings:
    print('WARN:', w)
for e in errors:
    print('FAIL:', e)
if errors:
    sys.exit(1)
print('OK: %d topic files, all indexed, all closed with a "Reads with:" line' % len(topic_files))
