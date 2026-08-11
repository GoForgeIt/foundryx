#!/usr/bin/env node
// G-M11 — "The phone is Solleva"
//
//   node scripts/check-m11.mjs [--render <path to an xcodebuild test log>]
//
// Rules on M11's `sees`, verbatim from the hearth's milestones.json:
//
//   "You pick up your phone and the app is the same product as the desktop — same palette,
//    same chat law, the four tabs unchanged with Capture still first, one name on the
//    device, and the '-X' suffix gone."
//
// SIX CLAUSES: one binding + the sentence's five limbs. Exit 0 only when all six hold.
//
// ─────────────────────────────────────────────────────────────────────────────────────
// WHERE EVERY EXPECTED VALUE COMES FROM — the question five red-on-clean gates in this
// programme failed to ask.
//
//   • The ruled Solleva dispositions are PARSED from grain's own shipped Solleva layer,
//     `src/themes/grain-solleva.css`, out of its `@supports not (color: oklch(…))` hex
//     fallback block. Nothing here hardcodes a brand colour.
//   • The grain-token → Solleva-token MAPPING is PARSED from `src/themes/grain-solleva-compat.css`
//     §2, which is the layer that actually re-points grain's names on the desktop. So "the
//     phone's palette equals the desktop's" is measured against the very file that makes the
//     desktop's palette what it is, not against a second transcription of it.
//   • grain-swift's token names mirror the web names 1:1 — `--forge-blue` → `GrainColor.forgeBlue`
//     — a property grain states in `GrainColor.swift`'s own doc comment and which this gate
//     re-derives mechanically (kebab → camel) rather than tabulating.
//   • The phone's shipped values are PARSED from `GrainTokens.generated.swift`, the single
//     generated surface every Swift component reads through `GrainColor`.
//
// CAN THE SURFACE HOLD THE VALUE?  Yes, and that is checked, not assumed: the gate refuses
// to run if it cannot find the sol hex table, the compat mapping, or the generated Swift
// tokens, and it prints the size of every population it counted over.
//
// THE RENDERED LEG IS NOT OPTIONAL. A source scan cannot prove a string reaches a screen or
// that a page is the colour its tokens say. `--render` takes the log of
// `UITests/M11RenderProofUITests.swift` (see that file's output contract). Without it the
// gate is RED and says so — it does not quietly downgrade to source-only.
// ─────────────────────────────────────────────────────────────────────────────────────

import { readFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..');

const die = (msg) => { console.error(`G-M11 REFUSES TO RUN: ${msg}`); process.exit(2); };
const read = (p, what) => {
  if (!existsSync(p)) die(`${what} not found at ${p}`);
  return readFileSync(p, 'utf8');
};
const git = (cwd, ...args) => {
  try { return execFileSync('git', args, { cwd, encoding: 'utf8' }).trim(); }
  catch { return null; }
};

// ── where grain-swift is, according to the app's OWN dependency declaration ──────────
// Not a constant here. `Package.swift` says `.package(name: "Grain", path: "../grain/…")`
// and repo-seams.md §3.5 makes that relative sibling pin load-bearing: a worktree not
// beside its grain fails. This gate inherits that seam instead of inventing a second one.
const pkg = read(join(REPO, 'Package.swift'), 'Package.swift');
const pinMatch = pkg.match(/\.package\(\s*name:\s*"Grain",\s*path:\s*"([^"]+)"\s*\)/);
if (!pinMatch) die('Package.swift declares no `name: "Grain", path:` sibling pin — the seam this gate reads is gone');
const GRAIN_SWIFT = resolve(REPO, pinMatch[1]);
if (!existsSync(GRAIN_SWIFT)) {
  die(`Package.swift pins Grain at "${pinMatch[1]}" → ${GRAIN_SWIFT}, which does not exist.\n` +
      `  This is the loud failure repo-seams.md §3.5 requires: a foundryx worktree that is not\n` +
      `  beside a grain checkout cannot be measured, and must not be silently measured anyway.`);
}
const GRAIN = resolve(GRAIN_SWIFT, '..', '..');

// ── population helpers ───────────────────────────────────────────────────────────────
const kebabToCamel = (s) => s.replace(/^--/, '').replace(/-([a-z])/g, (_, c) => c.toUpperCase());
const hex = (r, g, b) =>
  '#' + [r, g, b].map((v) => Math.round(v * 255).toString(16).padStart(2, '0').toUpperCase()).join('');

const clauses = [];
const clause = (id, ok, line, sub = []) => clauses.push({ id, ok, line, sub });
const out = [];
const say = (s = '') => out.push(s);

say('G-M11 — the phone is Solleva');

// ═════════════════════════════════════════════════════════════════════════════════════
// CLAUSE 1 — measured-ref binding.  Which bytes did this run actually read?
// ═════════════════════════════════════════════════════════════════════════════════════
const fxSha = git(REPO, 'rev-parse', 'HEAD');
const grSha = git(GRAIN, 'rev-parse', 'HEAD');
const anc = (cwd, sha) => {
  if (!sha) return 'no-git';
  try { execFileSync('git', ['merge-base', '--is-ancestor', sha, 'origin/main'], { cwd }); return 'yes'; }
  catch { return 'NO'; }
};
const fxAnc = anc(REPO, fxSha), grAnc = anc(GRAIN, grSha);
const fxDirty = (git(REPO, 'status', '--porcelain') || '').split('\n').filter(Boolean).length;
const grDirty = (git(GRAIN, 'status', '--porcelain') || '').split('\n').filter(Boolean).length;

const bindOK = fxAnc === 'yes' && grAnc === 'yes' && grDirty === 0;
clause('measured-ref', bindOK,
  bindOK
    ? `both trees are on origin/main — foundryx ${fxSha?.slice(0, 8)} · grain ${grSha?.slice(0, 8)}`
    : `the measured bytes are NOT origin/main bytes — foundryx ${fxSha?.slice(0, 8)} ancestor-of-origin/main=${fxAnc}, grain ${grSha?.slice(0, 8)} ancestor-of-origin/main=${grAnc}, grain worktree dirty=${grDirty} file(s)`,
  [`grain-swift resolved through Package.swift's own pin "${pinMatch[1]}" → ${GRAIN_SWIFT}`,
   `foundryx worktree dirty: ${fxDirty} file(s) (INFORMATION — the gate's own new files land here)`]);

// ═════════════════════════════════════════════════════════════════════════════════════
// CLAUSE 2 — same palette.
// ═════════════════════════════════════════════════════════════════════════════════════
const sollevaCss = read(join(GRAIN, 'src/themes/grain-solleva.css'), "grain's Solleva layer");
const compatCss = read(join(GRAIN, 'src/themes/grain-solleva-compat.css'), "grain's Solleva compat layer");
const swiftTokens = read(join(GRAIN_SWIFT, 'Sources/Grain/Tokens/GrainTokens.generated.swift'),
                         "grain-swift's generated tokens");

// the ruled --sol-* hex table
const supportsBlock = sollevaCss.match(/@supports not \(color: oklch\([^)]*\)\)\s*\{([\s\S]*?)\n\}/);
if (!supportsBlock) die('grain-solleva.css has no `@supports not (color: oklch(…))` hex block — the ruled hex table this gate reads is gone');
const SOL = new Map();
for (const m of supportsBlock[1].matchAll(/(--sol-[a-z0-9-]+)\s*:\s*(#[0-9A-Fa-f]{6})/g)) {
  SOL.set(m[1], m[2].toUpperCase());
}
if (SOL.size === 0) die('the @supports block parsed to 0 --sol-* hexes');

// the grain-name → --sol-* mapping, light (:root) only
const rootBlocks = [...compatCss.matchAll(/:root\s*\{([\s\S]*?)\n\}/g)].map((m) => m[1]).join('\n');
const MAP = new Map();
for (const m of rootBlocks.matchAll(/(--[a-z0-9-]+)\s*:\s*var\((--sol-[a-z0-9-]+)\)/g)) {
  if (m[1].startsWith('--sol-')) continue;
  MAP.set(m[1], m[2]);
}
if (MAP.size === 0) die('grain-solleva-compat.css :root parsed to 0 grain→sol re-points');

// the phone's shipped light values
const SWIFT = new Map();
for (const m of swiftTokens.matchAll(
  /public static let ([A-Za-z0-9_]+) = ColorPair\(light: Color\(\.sRGB, red: ([\d.]+), green: ([\d.]+), blue: ([\d.]+), opacity: ([\d.]+)\)/g)) {
  if (Number(m[5]) < 0.999) continue;   // translucent washes have no single hex to compare
  SWIFT.set(m[1], hex(Number(m[2]), Number(m[3]), Number(m[4])));
}
if (SWIFT.size === 0) die('GrainTokens.generated.swift parsed to 0 opaque light ColorPairs');

const grainColorSwift = read(join(GRAIN_SWIFT, 'Sources/Grain/Tokens/GrainColor.swift'), 'GrainColor.swift');
const sollevaMentions = execFileSync('bash', ['-lc',
  `grep -rIo 'sol-\\|Solleva' ${JSON.stringify(join(GRAIN_SWIFT, 'Sources'))} | wc -l`],
  { encoding: 'utf8' }).trim();

// the comparable population: a grain token that the compat layer re-points AND that
// grain-swift actually ships as an opaque colour.
let agree = 0; const disagree = [];
let comparable = 0;
const mappedButNotInSwift = [];
const solMissingHex = [];
for (const [grainVar, solVar] of MAP) {
  const camel = kebabToCamel(grainVar);
  const want = SOL.get(solVar);
  if (!want) { solMissingHex.push(`${grainVar}→${solVar}`); continue; }
  if (!SWIFT.has(camel)) { mappedButNotInSwift.push(`${grainVar} (${camel})`); continue; }
  comparable++;
  if (SWIFT.get(camel) === want) agree++;
  else disagree.push(`${camel} phone=${SWIFT.get(camel)} desktop=${want} (${solVar})`);
}
const paletteOK = comparable > 0 && disagree.length === 0;
clause('same-palette', paletteOK,
  paletteOK
    ? `all ${comparable} comparable tokens match the desktop's Solleva value`
    : `${agree} of ${comparable} comparable tokens carry the desktop's Solleva value — ${disagree.length} still carry the retired Forge floor`,
  [`ruled dispositions parsed from grain-solleva.css @supports block: ${SOL.size}`,
   `grain→sol re-points parsed from grain-solleva-compat.css :root: ${MAP.size}`,
   `opaque light ColorPairs parsed from GrainTokens.generated.swift: ${SWIFT.size}`,
   `EXCLUDED — re-pointed but grain-swift ships no such token: ${mappedButNotInSwift.length}` +
     (mappedButNotInSwift.length ? ` [${mappedButNotInSwift.slice(0, 8).join(', ')}${mappedButNotInSwift.length > 8 ? ', …' : ''}]` : ''),
   `EXCLUDED — re-pointed to a --sol-* with no hex in the fallback block (color-mix/alpha): ${solMissingHex.length}`,
   ...disagree.slice(0, 12).map((d) => `  ✗ ${d}`),
   ...(disagree.length > 12 ? [`  … and ${disagree.length - 12} more`] : []),
   `Solleva references anywhere in grain-swift's whole source tree: ${sollevaMentions}`,
   `OC-5 phone half (INFORMATION, already true): ColorPair.dynamic resolves ${
     /userInterfaceStyle == \.dark/.test(grainColorSwift) ? 'UITraitCollection.userInterfaceStyle' : '(NOT the system appearance)'
   }, so whatever values land will follow the system theme — the night BLOCK is what is missing, not the mechanism`]);

// ── T-SWIFT-PORT's component census, re-run rather than carried ──────────────────────
// The track requires the count be re-derived at every start and reported WITH the size of
// what the predicate excluded, because the number that survived the first pass (31) came
// from a predicate that could not see a type-parameter list before `: View`. The predicate
// below therefore makes the generic list explicit and optional, and the run prints the
// generic subset separately so the two numbers can never merge back into one.
const censusFiles = execFileSync('bash', ['-lc',
  `find ${JSON.stringify(join(GRAIN_SWIFT, 'Sources/Grain'))} -name '*.swift' | sort`],
  { encoding: 'utf8' }).split('\n').filter(Boolean);
const components = [], nonViewPublicStructs = [];
let nestedOrPrivateViews = 0;
for (const f of censusFiles) {
  const src = readFileSync(f, 'utf8');
  for (const m of src.matchAll(/^public struct ([A-Za-z0-9_]+)\s*(<.*?>)?\s*:\s*([^{]*)/gm)) {
    const first = m[3].split(',')[0].split('where')[0].trim();
    (first === 'View' ? components : nonViewPublicStructs).push({ name: m[1], generic: !!m[2], f });
  }
  nestedOrPrivateViews += (src.match(/^\s+(?:public |private |internal |fileprivate )?struct \w+\s*(?:<.*?>)?\s*:\s*View/gm) || []).length;
}
say('');
say('  ── T-SWIFT-PORT census, re-run over grain-swift (not carried) ──');
say(`  population — top-level \`public struct X[<…>]: View\`: ${components.length}` +
    ` (${components.filter((c) => c.generic).length} generic, ${components.filter((c) => !c.generic).length} non-generic)` +
    ` across ${new Set(components.map((c) => c.f)).size} of ${censusFiles.length} files`);
say(`  EXCLUDED — top-level public structs whose first conformance is not View: ${nonViewPublicStructs.length}` +
    ` [${[...new Set(nonViewPublicStructs.map((c) => c.name))].join(', ')}]`);
say(`  EXCLUDED — nested or non-public structs conforming to View (previews, private subviews): ${nestedOrPrivateViews}`);
say(`  the generics a predicate without \`(<.*?>)?\` cannot see: ${components.filter((c) => c.generic).map((c) => c.name).join(', ')}`);

// ═════════════════════════════════════════════════════════════════════════════════════
// THE RENDERED LEG — parsed ONCE, here, because three clauses rule on it.
//
// It used to be parsed at CLAUSE 6 and consumed by CLAUSE 6 alone. `M11-TABS`,
// `M11-SELECTED` and `M11-APP-LABEL` were read off the running app, PRINTED at the foot of
// the report, and then ruled on by nothing — so `four-tabs-capture-first` and
// `one-name-on-the-device` were decided entirely by re-reading the two Swift files the app
// is built from. EXECUTED 2026-08-09: a log whose tab bar read
// `Settings · Today · Capture · Chats · Extra` and whose app label read `FoundryX` still
// scored 6 of 6, EXIT=0, with the contradicting line printed in the same output. That is
// this programme's own law — ASSERT THE OUTCOME, NEVER THE ANNOUNCEMENT — failing inside
// the gate that was supposed to enforce it. Fixed by moving the parse above the clauses
// that need it and making both of them consume it.
// ═════════════════════════════════════════════════════════════════════════════════════
let renderLines = null;
const rIdx = process.argv.indexOf('--render');
if (rIdx > -1 && process.argv[rIdx + 1]) {
  renderLines = read(process.argv[rIdx + 1], 'the render-proof log')
    .split('\n').filter((l) => l.startsWith('M11-'));
}
const NO_RENDER = 'NOT RUN — pass --render <xcodebuild test log of M11RenderProofUITests>. The gate does not downgrade to source-only.';
const PARTIAL = 'INCOMPLETE — the render proof produced no M11-END line, so its census is partial and cannot be trusted.';
let renderSummary, renderOKForX = false;
let renderedTabs = null, renderedName = null, renderedSelected = null, dominants = [];
const renderUsable = !!renderLines && renderLines.some((l) => l === 'M11-END');
if (!renderLines) {
  renderSummary = NO_RENDER;
} else if (!renderUsable) {
  renderSummary = PARTIAL;
} else {
  renderedName = renderLines.find((l) => l.startsWith('M11-APP-LABEL:'))?.slice(15).trim();
  renderedTabs = renderLines.find((l) => l.startsWith('M11-TABS:'))?.slice(9).split('|').map((s) => s.trim());
  renderedSelected = renderLines.find((l) => l.startsWith('M11-SELECTED:'))?.slice(13).trim();
  dominants = renderLines.filter((l) => l.startsWith('M11-DOMINANT')).map((l) => l.split(/\s+/));
  const strings = renderLines.filter((l) => l.startsWith('M11-STRING '));
  const totals = renderLines.filter((l) => l.startsWith('M11-STRINGS-TOTAL'))
    .map((l) => Number(l.split(/\s+/)[2]));
  const readCount = totals.reduce((a, b) => a + b, 0);
  renderOKForX = strings.length === 0 && readCount > 0;
  renderSummary = `${strings.length} rendered string(s) containing "Foundry" over ${readCount} string(s) actually read across ${totals.length} tab root(s)` +
    (strings.length ? `: ${strings.map((s) => s.replace(/^M11-STRING /, '')).join('; ')}` : '');
}

// ═════════════════════════════════════════════════════════════════════════════════════
// CLAUSE 3 — same chat law.
// ═════════════════════════════════════════════════════════════════════════════════════
const shell = read(join(REPO, 'Sources/FoundryXKit/AppShellPresentation.swift'), 'AppShellPresentation.swift');
const chatView = read(join(REPO, 'Sources/FoundryXKit/ChatView.swift'), 'ChatView.swift');
const bubble = read(join(GRAIN_SWIFT, 'Sources/Grain/Components/Chat/GrainMessageBubble.swift'), 'GrainMessageBubble.swift');
const localChat = read(join(REPO, 'App/LocalChatScreen.swift'), 'LocalChatScreen.swift');
const chatScreen = read(join(REPO, 'App/ChatScreen.swift'), 'ChatScreen.swift');

const chatLabel = shell.match(/case \.chat:\s*return "([^"]+)"/)?.[1] ?? '(unparsed)';
const labelOK = chatLabel === 'Chats';

// mine-right / others-left, as the shape rather than as a comment: inside the bubble's
// HStack, `.user` puts a Spacer BEFORE the text and `.assistant` puts one AFTER. Verified on
// disk 2026-08-05 to ALREADY hold, so this is the regression guard T-PHONE-CHATLAW asked
// for, not new work — and it is asserted by ORDER OF APPEARANCE rather than by a
// fixed-width window, because the first draft of this check used `[\s\S]{0,400}` between the
// two Spacers and went red on a tree where the shape was perfectly correct. A distance
// threshold is not the property; the order is.
const iUser = bubble.search(/if role == \.user \{\s*Spacer\(/);
const iAsst = bubble.search(/if role == \.assistant \{\s*Spacer\(/);
const iText = bubble.search(/\n\s*Text\(text\)/);
const userSpacerFirst = iUser > -1 && iAsst > -1 && iText > -1 && iUser < iText && iText < iAsst;
const chatViewBothRoles = /role:\s*\.assistant/.test(chatView) && /role:\s*\.user/.test(chatView);
const localThroughSurface = /ChatSurface/.test(localChat);
const alignmentOK = userSpacerFirst && chatViewBothRoles && localThroughSurface;

// The header's five controls become three: no interactive model picker survives.
//
// COMMENTS ARE STRIPPED FIRST, and that is not tidiness. The first draft counted raw
// occurrences of `ModelPickerMenu` in ChatScreen.swift. Applying the very commit that DELETES
// the picker left the count at 2 — both of them comments saying it had been deleted — so the
// check would have gone on reporting a picker that no longer exists, and the fix would have
// looked like a failure. A check that cannot tell a control from an epitaph is measuring
// prose, not the header.
const decomment = (s) => s.replace(/^\s*\/\/.*$/gm, '').replace(/\s\/\/[^"\n]*$/gm, '');
const pickerHits = (decomment(chatScreen).match(/ModelPickerMenu/g) || []).length;
const pickerCommentHits = (chatScreen.match(/ModelPickerMenu/g) || []).length - pickerHits;
const pickerOK = pickerHits === 0;

const chatLawOK = labelOK && alignmentOK && pickerOK;
clause('same-chat-law', chatLawOK,
  chatLawOK ? 'the tab reads Chats, the header carries no picker, and mine-right/others-left holds'
            : `${[labelOK, pickerOK, alignmentOK].filter(Boolean).length} of 3 sub-assertions hold`,
  [`${labelOK ? '✓' : '✗'} chats-tab-label       AppTab.chat.label = "${chatLabel}" (M11 rules "Chats")`,
   `${pickerOK ? '✓' : '✗'} no-model-picker       ChatScreen.swift names ModelPickerMenu ${pickerHits}× in code (${pickerCommentHits}× more in comments, which do not count)`,
   `${alignmentOK ? '✓' : '✗'} mine-right-others-left  GrainMessageBubble Spacer shape=${userSpacerFirst}, ChatView passes both roles=${chatViewBothRoles}, LocalChatScreen through ChatSurface=${localThroughSurface}`]);

// ═════════════════════════════════════════════════════════════════════════════════════
// CLAUSE 4 — the four tabs unchanged with Capture still first.
// ═════════════════════════════════════════════════════════════════════════════════════
const cases = (shell.match(/case capture[^\n]*/)?.[0] ?? '')
  .replace(/^case /, '').split(',').map((s) => s.trim()).filter(Boolean);
const rootView = read(join(REPO, 'App/RootView.swift'), 'RootView.swift');
const tabItems = [...rootView.matchAll(/\.tabItem \{ Label\(AppTab\.([a-z]+)\.label/g)].map((m) => m[1]);
const launch = shell.match(/static let launch: AppTab = \.([a-z]+)/)?.[1];
const activityLabel = shell.match(/case \.activity:\s*return "([^"]+)"/)?.[1];
const orderOK = JSON.stringify(cases) === JSON.stringify(['capture', 'activity', 'chat', 'settings']);
const wiredOK = JSON.stringify(tabItems) === JSON.stringify(cases);
const launchOK = launch === 'capture';
const iaD8OK = activityLabel === 'Activity';   // IA-D8: the phone shows Activity, never Today

// The bar the OS actually drew. `cases` and `tabItems` are two readings of the SOURCE; a
// tab bar is a claim about a screen, so the screen is the population that settles it. The
// expected value is not written here either — it is the label each declared case returns
// from AppShellPresentation, so a renamed tab moves the expectation and the render together
// and this can only go red on a real disagreement between the two.
const labelOf = (c) => shell.match(new RegExp(`case \\.${c}:\\s*return "([^"]+)"`))?.[1] ?? `(unparsed:${c})`;
const declaredLabels = cases.map(labelOf);
const renderedTabsOK = renderUsable && JSON.stringify(renderedTabs) === JSON.stringify(declaredLabels);
const renderedSelectedOK = renderUsable && renderedSelected === labelOf(launch);
const renderedTabsLine = !renderLines
  ? `✗ rendered tab bar: ${NO_RENDER}`
  : !renderUsable
    ? `✗ rendered tab bar: ${PARTIAL}`
    : `${renderedTabsOK ? '✓' : '✗'} the OS drew: ${renderedTabs.join(' · ')} (${renderedTabs.length}) — declared labels: ${declaredLabels.join(' · ')}`;
const renderedSelectedLine = !renderUsable
  ? `✗ the launched tab: unmeasured — no usable render proof`
  : `${renderedSelectedOK ? '✓' : '✗'} the app launched onto "${renderedSelected}" and AppTab.launch = .${launch} → "${labelOf(launch)}"`;

const tabsOK = orderOK && wiredOK && launchOK && iaD8OK && renderedTabsOK && renderedSelectedOK;
clause('four-tabs-capture-first', tabsOK,
  tabsOK ? `exactly ${cases.length} tabs, Capture first, and the second place reads "Activity" — on the screen, not only in source`
         : 'the tab set, its order, its launch tab, IA-D8 or the RENDERED bar does not hold',
  [`${orderOK ? '✓' : '✗'} declared: ${cases.join(' · ')} (${cases.length})`,
   `${wiredOK ? '✓' : '✗'} wired by RootView in the same order: ${tabItems.join(' · ')} (${tabItems.length}) — a SOURCE reading, not a rendered one`,
   `${launchOK ? '✓' : '✗'} AppTab.launch = .${launch}`,
   `${iaD8OK ? '✓' : '✗'} IA-D8 — the second place reads "${activityLabel}", never "Today"`,
   renderedTabsLine,
   renderedSelectedLine,
   `    NOTE — M11-SELECTED is only honest on a device the app was NEVER installed on. simctl uninstall leaves state behind and has been measured returning "Settings" from the same build.`]);

// ═════════════════════════════════════════════════════════════════════════════════════
// CLAUSE 5 — one name on the device.
// ═════════════════════════════════════════════════════════════════════════════════════
// "On the device" = what the OS registers and speaks: the two bundle display names and the
// App Intents / Siri phrases. A phrase that hardcodes a product name can drift from the
// bundle; a phrase built from `\(.applicationName)` cannot, which is why the shape is
// asserted and not only the string.
// The population is the SHIPPED bundles only. The first draft of this check globbed every
// `CFBundleDisplayName:` in project.yml and went red on "Pairing Keychain Test Host" — a
// unit-test host that never reaches a customer's device. A name census whose population
// includes targets that do not ship is not measuring "one name on the device".
const projectYml = read(join(REPO, 'project.yml'), 'project.yml');
const targetsSection = projectYml.slice(projectYml.indexOf('\ntargets:'));
const shipped = [], notShipped = [];
for (const m of targetsSection.matchAll(/\n  ([A-Za-z0-9_]+):\n([\s\S]*?)(?=\n  [A-Za-z0-9_]+:\n|\n[a-z]+:\n|$)/g)) {
  const [, name, body] = m;
  const type = body.match(/\n    type:\s*(\S+)/)?.[1] ?? '(none)';
  const dn = body.match(/CFBundleDisplayName:\s*(.+)/)?.[1]?.trim();
  if (!dn) continue;
  (/test/i.test(type) || /test/i.test(name) ? notShipped : shipped).push({ name, type, dn });
}
if (shipped.length === 0) die('project.yml parsed to 0 shipping targets carrying a CFBundleDisplayName');
const displayNames = shipped.map((t) => t.dn);
const distinctNames = [...new Set(displayNames)];
const SRC_ROOTS = ['App', 'Sources', 'Widget'];
const files = execFileSync('bash', ['-lc',
  SRC_ROOTS.map((r) => `find ${JSON.stringify(join(REPO, r))} -name '*.swift'`).join('; ')],
  { encoding: 'utf8' }).split('\n').filter(Boolean);

// The SEAM-D4 carve-out, COUNTED rather than waved at. These are the bare-"Foundry" literals
// the rename deliberately left alone because the agent's name is an unruled decision. They are
// excluded from the clause, but a reader of this gate is owed the number: every one of them is
// a place a customer still reads the retired product name.
const seamD4Sites = [];
for (const f of files) {
  const rel = f.replace(REPO + '/', '');
  readFileSync(f, 'utf8').split('\n').forEach((line, i) => {
    const t = line.trim();
    if (t.startsWith('//') || t.startsWith('*')) return;
    for (const m of line.matchAll(/"((?:[^"\\\n]|\\.)*)"/g)) {
      if (/Foundry/.test(m[1]) && !m[1].includes('FoundryX')) seamD4Sites.push(`${rel}:${i + 1}`);
    }
  });
}

const shortcuts = read(join(REPO, 'App/FoundryXShortcuts.swift'), 'FoundryXShortcuts.swift');
const phrases = [...shortcuts.matchAll(/phrases:\s*\[([\s\S]*?)\]/g)].map((m) => m[1]);
const phraseLiterals = phrases.flatMap((p) => [...p.matchAll(/"([^"]*)"/g)].map((m) => m[1]));
const phrasesHardcoding = phraseLiterals.filter((p) => /Foundry|Solleva/.test(p));

// "on the device" is settled by the device. project.yml is the INTENT; `app.label` is what
// iOS registered and shows under the icon, and the two can diverge — a stale Info.plist, a
// build that did not pick up the rename, an install the OS kept the old label for. The
// expected value is the one distinct shipped display name, so nothing is hardcoded here.
const renderedNameOK = renderUsable && distinctNames.length === 1 && renderedName === distinctNames[0];
const renderedNameLine = !renderLines
  ? `✗ the name the OS shows: ${NO_RENDER}`
  : !renderUsable
    ? `✗ the name the OS shows: ${PARTIAL}`
    : `${renderedNameOK ? '✓' : '✗'} the OS shows the app as "${renderedName}"; the shipped bundles declare "${distinctNames.join(' | ')}"`;

const nameOK = distinctNames.length === 1 && phrasesHardcoding.length === 0 && phraseLiterals.length > 0
               && renderedNameOK;
clause('one-name-on-the-device', nameOK,
  nameOK ? `one name — "${distinctNames[0]}" — across ${displayNames.length} bundle(s) and ${phraseLiterals.length} OS-registered phrase(s), and it is the name the OS shows`
         : [`${distinctNames.length} distinct display name(s): ${distinctNames.join(' | ')}`,
            `${phrasesHardcoding.length} phrase(s) hardcode a product name`,
            renderedNameOK ? null
              : renderUsable ? `the OS shows "${renderedName}", which is not the declared name`
                             : 'the name the OS shows was not measured'].filter(Boolean).join('; '),
  [`SHIPPED bundles carrying a display name (${shipped.length}): ${shipped.map((t) => `${t.name}[${t.type}]="${t.dn}"`).join(', ')}`,
   `EXCLUDED — non-shipping targets (${notShipped.length}): ${notShipped.map((t) => `${t.name}[${t.type}]="${t.dn}"`).join(', ') || '—'}`,
   `Siri/App Intents phrases parsed: ${phraseLiterals.length}, of which ${phraseLiterals.filter((p) => p.includes('.applicationName')).length} are built from \\(.applicationName) and so cannot drift from the bundle`,
   renderedNameLine,
   `EXCLUDED — SEAM-D4, the default AGENT name, ${seamD4Sites.length} site(s) still reading "Foundry": ${seamD4Sites.join(', ')}`,
   `    SEAM-D4 is PENDING-B → awaiting Nick (lane B screened SOLA NO and supplied B-1, a plain owner-editable role noun; Nick has ruled neither). An agent's name is not a device name, so these are out of this clause's population by RULE — but they ARE ${seamD4Sites.length} place(s) where a customer reads a second, retired product name on the device. This clause is green only under the amended reading of M11's "one name"; see milestone-verification-m11.md §"the amendment".`]);

// ═════════════════════════════════════════════════════════════════════════════════════
// CLAUSE 6 — the "-X" suffix gone.
// ═════════════════════════════════════════════════════════════════════════════════════
// Population: every double-quoted literal containing "FoundryX" in the three shipped source
// roots, comment lines excluded. Each is classified, and EVERY exclusion is a named rule
// with a reason — never "looks internal to me".
//
// The exclusions are SITE-SCOPED, not pattern-scoped, and this is the whole discipline of
// the clause. The first draft excluded any literal that was exactly `"FoundryX"` on the
// theory that a bare token must be an identifier. That rule silently swallowed FIVE strings
// that a customer reads: `KilnLibrary.sourceLabel`/`sourceTag` and `ChatProvenance` produce
// the HUMAN source label, and `App/KilnConversationView.swift:118` renders it as
// `Text(tag.label)` on a conversation's provenance row. A bare token is not evidence of
// anything; where it is CONSUMED is. Anything not listed below counts as customer-visible —
// the fail-loud direction, so a new site can never be excluded by silence.
const CLASSES = [
  ['identifier', [
    ['Sources/FoundryXKit/FoundryAuth.swift', /^FoundryXOAuth$/, 'an Info.plist dictionary key'],
    ['Sources/FoundryXKit/HostResolver.swift', /^FoundryXOAuth$/, 'an Info.plist dictionary key'],
    ['Sources/FoundryXKit/AccountPreferenceUsageGuard.swift', /^Sources\/FoundryXKit$/, 'a source-tree path in a lint allowlist'],
    ['Sources/FoundryXKit/CaptureAccountScope.swift', /^FoundryX$/, 'the on-disk container directory name — renaming it orphans every existing capture'],
    ['App/PerfMetricsSubscriber.swift', /^FoundryX$/, 'the binary/stack-frame name PerfDiag matches against'],
    ['Sources/FoundryXKit/LiveTranscriber.swift', /^FoundryX$/, 'a speech-recognition vocabulary hint — it teaches the recogniser a word people still say'],
    ['Widget/CaptureStatusWidget.swift', /^FoundryXCaptureStatusWidget$/, 'the WidgetKit kind identifier, which is persisted by the OS per installed widget'],
  ], 'bytes the OS, a persisted path or a lint allowlist keys on — repo-seams.md §3.3 requires these stay unchanged'],
  ['diagnostic', [
    ['Sources/FoundryXKit/DoorLog.swift', /device log|log entries this session/, 'a developer log header'],
    ['Sources/FoundryXKit/RemoteSession.swift', /^FoundryX \\\(ver\)/, 'a diagnostic session header'],
    ['Sources/FoundryXKit/FoundryAuth.swift', /client id not set in Info\.plist/, 'a thrown configuration error naming the Info.plist key above'],
  ], 'a developer diagnostic, not product chrome'],
];

const visible = [], excluded = { identifier: [], diagnostic: [] };
let literalsScanned = 0;
for (const f of files) {
  const rel = f.replace(REPO + '/', '');
  readFileSync(f, 'utf8').split('\n').forEach((line, i) => {
    const t = line.trim();
    if (t.startsWith('//') || t.startsWith('*')) return;
    for (const m of line.matchAll(/"((?:[^"\\\n]|\\.)*)"/g)) {
      literalsScanned++;
      const v = m[1];
      if (!v.includes('FoundryX')) continue;
      let hit = null;
      for (const [kind, sites] of CLASSES) {
        const s = sites.find(([file, re]) => rel === file && re.test(v));
        if (s) { hit = [kind, s[2]]; break; }
      }
      if (hit) excluded[hit[0]].push(`${rel}:${i + 1} «${v.slice(0, 62)}» — ${hit[1]}`);
      else visible.push(`${rel}:${i + 1} «${v.slice(0, 70)}»`);
    }
  });
}

const xOK = visible.length === 0 && renderOKForX;
clause('x-suffix-gone', xOK,
  xOK ? 'no customer-visible "FoundryX" survives, in source or on the screen'
      : `${visible.length} customer-visible "FoundryX" string(s) remain in source`,
  [`literals scanned across ${files.length} shipped .swift files: ${literalsScanned}`,
   `EXCLUDED — identifier (${excluded.identifier.length}): ${CLASSES[0][2]}`,
   ...excluded.identifier.map((s) => `    · ${s}`),
   `EXCLUDED — diagnostic (${excluded.diagnostic.length}): ${CLASSES[1][2]}`,
   ...excluded.diagnostic.map((s) => `    · ${s}`),
   `CUSTOMER-VISIBLE (${visible.length}):`,
   ...visible.map((s) => `    ✗ ${s}`),
   `rendered leg: ${renderSummary}`,
   renderLines ? `  LIMIT OF THE RENDERED WALK: it visits the ${renderedTabs?.length ?? 0} tab roots only. The Pocket onboarding flow, the Vault funnel, error states and the home-screen widget are NOT reached, and most of the source hits above live there — so a clean rendered census is NOT evidence those strings are gone.` : '']);

// ═════════════════════════════════════════════════════════════════════════════════════
// the rendered palette + tab census, reported against the source clauses
// ═════════════════════════════════════════════════════════════════════════════════════
if (renderLines) {
  say('');
  say('  ── measured on the running app (iOS Simulator) ──');
  say(`  the OS shows the app as: ${renderedName}`);
  say(`  the tab bar renders: ${renderedTabs?.join(' · ')} (${renderedTabs?.length})`);
  const solSet = new Set([...SOL.values()]);
  const forgeSet = new Set([...SWIFT.values()]);
  for (const d of dominants) {
    const [, tab, h, share] = d;
    const fam = solSet.has(h) ? 'a ruled Solleva disposition'
      : forgeSet.has(h) ? 'a retired Forge-floor token'
      : 'neither table';
    say(`  ${d[0].replace('M11-DOMINANT', 'dominant').padEnd(11)} ${tab.padEnd(9)} ${h}  ${share.padStart(13)}  ${fam}`);
  }
}

// ═════════════════════════════════════════════════════════════════════════════════════
say('');
for (const c of clauses) {
  say(`${c.ok ? '✓' : '✗'} ${c.id.padEnd(24)} ${c.line}`);
  for (const s of c.sub.filter(Boolean)) say(`    ${s}`);
}
const green = clauses.filter((c) => c.ok).length;
say('');
say(`${green === clauses.length ? 'GREEN' : 'RED'} — ${green} of ${clauses.length} clauses hold`);
console.log(out.join('\n'));
process.exit(green === clauses.length ? 0 : 1);
