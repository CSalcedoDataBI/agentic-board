// agentic-board dsh sandbox (#773): fail the image build unless the COMPOSED headless profile has
// every upload row disabled. Reads `dsh --dump-config` output on stdin. The dump is YAML with
// custom !!js tags, so it is checked as text: one block per "- id: <row>" at column 0, and the row
// must carry "  disabled: true" (the row's own key, two-space indent). A row that is missing, or
// present more than once, also fails: with a pinned version the shape is known, anything else is
// a surprise and the build stops (fail closed).
'use strict';
const rows = ['session-log-deepseek', 'session-telemetry-otel', 'plugin-package-inventory-deepseek'];
let text = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => { text += c; });
process.stdin.on('end', () => {
    const blocks = text.split(/^(?=- id: )/m);
    let failed = false;
    for (const id of rows) {
        const mine = blocks.filter((b) => b.startsWith(`- id: ${id}\n`));
        if (mine.length !== 1) { console.error(`abios-dsh: row ${id} found ${mine.length} times in the composed config`); failed = true; continue; }
        if (!/^  disabled: true$/m.test(mine[0])) { console.error(`abios-dsh: upload row ${id} is NOT disabled`); failed = true; continue; }
        console.log(`${id}: disabled`);
    }
    process.exit(failed ? 1 : 0);
});
