// Generate calibration grid firmware for HMI430
// White buttons turn black WHILE pressed (pb: parameter). No event handlers.
// 6x5 grid = exactly 30 buttons, all with id:0-29 (HMI limit).
const fs = require('fs');

const SCREEN_W = 480, SCREEN_H = 272;
const COLS = 6, ROWS = 5;
const cellW = Math.floor(SCREEN_W / COLS);  // 80
const cellH = Math.floor(SCREEN_H / ROWS);  // 54
const total = COLS * ROWS;

console.log(`Grid: ${COLS}x${ROWS} = ${total} buttons, cell=${cellW}x${cellH}px`);

let spt = `; ui_test.spt -- calibration grid (${COLS}x${ROWS}, ${cellW}x${cellH}px)\n`;
spt += `; White buttons turn black while pressed (pb). No event handlers.\n`;
spt += `uiTask:\n`;
spt += `    YieldTask\n`;
spt += `    YieldTask\n`;
spt += `uiTask_draw:\n`;
spt += `    GoSub drawGrid\n`;
spt += `    YieldTask\n`;
spt += `    YieldTask\n`;
spt += `uiTask_idle:\n`;
spt += `    Pause 500\n`;
spt += `    GoTo uiTask_idle\n\n`;

spt += `drawGrid:\n`;
spt += `    #HMI SetColours(f:'FF000000, b:'FFFFFFFF)\n`;
spt += `    #HMI Reset(b:0)\n`;
spt += `    ClrInstCount\n`;

let id = 0;
for (let r = 0; r < ROWS; r++) {
    for (let c = 0; c < COLS; c++) {
        const x = c * cellW;
        const y = r * cellH;
        // Remaining height for last row
        const h = (r === ROWS - 1) ? SCREEN_H - y : cellH;
        spt += `    #HMI ButtonEvent2(id:${id}, x:${x}px, y:${y}px, w:${cellW}px, h:${h}px, t:" ", rb:'FFFFFFFF, pb:'FF000000, ev:onPress)\n`;
        id++;
        if (id % 5 === 0) spt += `    ClrInstCount\n`;
    }
}
spt += `    Return\n\n`;
spt += `onPress:\n`;
spt += `    Return\n`;

fs.writeFileSync('C:/Claude/hmi430/ui_test.spt', spt);
console.log(`Wrote ui_test.spt: ${total} buttons`);
