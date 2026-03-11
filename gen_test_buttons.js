// gen_test_buttons.js -- Two tiny 4x4px buttons for mapping verification
// Button 0: center at (100, 100) -- 100px from top-left corner
// Button 1: center at (410, 202) -- 70px from bottom-right corner
const fs = require('fs');

const buttons = [
    { id: 0, name: 'near-TL', x: 98,  y: 98,  w: 4, h: 4 },
    { id: 1, name: 'near-BR', x: 408, y: 200, w: 4, h: 4 },
];

let spt = '; ui_test.spt -- mapping verification (2x 4x4px buttons)\n';
spt += 'uiTask:\n';
spt += '    YieldTask\n';
spt += '    YieldTask\n';
spt += 'uiTask_draw:\n';
spt += '    GoSub drawButtons\n';
spt += '    YieldTask\n';
spt += '    YieldTask\n';
spt += 'uiTask_idle:\n';
spt += '    Pause 500\n';
spt += '    GoTo uiTask_idle\n\n';

spt += 'drawButtons:\n';
spt += "    #HMI SetColours(f:'FF000000, b:'FFFFFFFF)\n";
spt += "    #HMI Reset(b:0)\n";

for (const b of buttons) {
    spt += `    #HMI ButtonEvent2(id:${b.id}, x:${b.x}px, y:${b.y}px, w:${b.w}px, h:${b.h}px, t:" ", rb:'FFFFFFFF, pb:'FF000000, ev:onPress)\n`;
}
spt += '    Return\n\n';
spt += 'onPress:\n';
spt += '    Return\n';

fs.writeFileSync('C:/Claude/hmi430/ui_test.spt', spt);
console.log(`Wrote ui_test.spt: ${buttons.length} buttons`);
buttons.forEach(b => console.log(`  ${b.name}: (${b.x},${b.y}) ${b.w}x${b.h} center=(${b.x+b.w/2},${b.y+b.h/2})`));
