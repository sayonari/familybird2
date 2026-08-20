const fs = require('fs');
const path = require('path');
const jsnes = require(path.join(__dirname, '..', 'docs', 'jsnes.min.js'));

let fb = null;
const nes = new jsnes.NES({
  onFrame: (b) => { fb = b; },
  onAudioSample: () => {},
});
const rom = fs.readFileSync(path.join(__dirname, '..', 'build', 'FamilyBird2.nes'), 'binary');
nes.loadROM(rom);

function frames(n) { for (let i = 0; i < n; i++) nes.frame(); }
function press(btn, holdFrames=2) {
  nes.buttonDown(1, btn);
  frames(holdFrames);
  nes.buttonUp(1, btn);
  frames(2);
}
function uniqueColors() { return new Set(fb).size; }
function ramPeek(a) { return nes.cpu.mem[a]; }

frames(40);
console.log('boot: SCENE=', ramPeek(0x0E), 'colors=', uniqueColors());
press(jsnes.Controller.BUTTON_START); frames(30);
console.log('title: SCENE=', ramPeek(0x0E), 'colors=', uniqueColors());
press(jsnes.Controller.BUTTON_START); frames(12);
console.log('game: SCENE=', ramPeek(0x0E), 'GAME_ST=', ramPeek(0x19));
press(jsnes.Controller.BUTTON_A); frames(5);
console.log('after A: GAME_ST=', ramPeek(0x19), 'birdY=', ramPeek(0x30));
// 少し自動プレイ
let alive = 0;
for (let i = 0; i < 900; i++) {
  const birdY = ramPeek(0x30);
  const velH = ramPeek(0x33);
  if (birdY > 110 && velH < 0x80 && i % 2 === 0) {
    nes.buttonDown(1, jsnes.Controller.BUTTON_A);
  } else {
    nes.buttonUp(1, jsnes.Controller.BUTTON_A);
  }
  nes.frame();
  if (ramPeek(0x19) === 1) alive = i;
  if (ramPeek(0x19) === 2) break;
}
const score = Array.from({length:6},(_,d)=>ramPeek(0x1A+d)*10**d).reduce((a,b)=>a+b);
console.log('play: alive_until=', alive, 'score=', score, 'scroll=', ramPeek(0x16)*256+ramPeek(0x15));
console.log('final colors=', uniqueColors(), 'SCENE=', ramPeek(0x0E), 'GAME_ST=', ramPeek(0x19));
console.log(uniqueColors() > 4 && score >= 0 ? 'JSNES TEST OK' : 'JSNES TEST FAILED');
