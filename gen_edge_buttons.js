// gen_edge_buttons.js -- 5 small buttons for edge-finding calibration
// Center + 4 corners (20px from screen edges), each 40x40px
// White resting, black while pressed.
const fs = require('fs');

// Buttons need to be large enough for initial hit (~100px to absorb mapping error).
// Edge-finding precision is independent of button size.
const buttons = [
    { id: 0, name: 'center',       x: 180, y: 96,  w: 120, h: 80 },
    { id: 1, name: 'top-left',     x: 10,  y: 10,  w: 120, h: 80 },
    { id: 2, name: 'top-right',    x: 350, y: 10,  w: 120, h: 80 },
    { id: 3, name: 'bottom-left',  x: 10,  y: 182, w: 120, h: 80 },
    { id: 4, name: 'bottom-right', x: 350, y: 182, w: 120, h: 80 },
];

let spt = '; ui_test.spt -- edge calibration (5 buttons, 40x40px)\n';
spt += '; White buttons turn black while pressed.\n';
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
