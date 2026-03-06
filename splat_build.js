// splat_build.js - Compile SPLat projects with binary (.b1n) and listing (.lst) output
// Patches splat.exe SEA binary to:
//   1. Disable V8 code cache (so patched source is reparsed)
//   2. Inject eval(process.env._S||0) hook after successful compilation
// The _S env var contains JS code that writes n.program and n.list to disk.
//
// Usage: node splat_build.js [build_file]

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const SPLAT_EXE = (() => {
    const candidates = [
        path.join('C:', 'Claude', 'dash-application', 'resources', 'app', 'plugins',
            'splat-controls.splat-vscode', 'dist', 'bin', 'splat.exe'),
        path.join(process.env.LOCALAPPDATA || '',
            'Programs', 'dash-application', 'resources', 'app', 'plugins',
            'splat-controls.splat-vscode', 'dist', 'bin', 'splat.exe'),
    ];
    return candidates.find(p => fs.existsSync(p)) || candidates[0];
})();

if (!fs.existsSync(SPLAT_EXE)) {
    console.error('ERROR: splat.exe not found at:', SPLAT_EXE);
    process.exit(99);
}

const buildFile = process.argv[2] || '_build.b1d';
const buildPath = path.resolve(buildFile);
const buildDir = path.dirname(buildPath);
const baseName = path.basename(buildPath, path.extname(buildPath));

if (!fs.existsSync(buildPath)) {
    console.error('ERROR: Build file not found:', buildPath);
    process.exit(1);
}

// --- Patch splat.exe in memory ---
const exeBuf = Buffer.from(fs.readFileSync(SPLAT_EXE));

// Patch 1: Inject eval hook into $i.activate() compile handler
// After successful compilation, the method has variable `n` = {program, list, diagnostics, ...}
// where n.program and n.list are Buffer objects containing the binary and listing.
// We insert eval(process.env._S||0) which is harmless when _S is unset (evals to 0),
// and executes our file-writing code when _S is set.
const origStr = ',s&&process.exit(1)}m_failure(e){console.error(`${Xa("ERROR")}: ${e}.`),process.exit(1)}};';
const origBuf = Buffer.from(origStr);
const patchIdx = exeBuf.indexOf(origBuf);

if (patchIdx < 0) {
    console.error('ERROR: Could not find patch target in splat.exe (version mismatch?)');
    process.exit(99);
}

// Replacement: 70 bytes core + comment padding to fill remaining space
// Uses _S env var (not _ which bash auto-sets)
const core = ',!s&&eval(process.env._S||0),s&&process.exit(1)}m_failure(e){throw e}};';
const coreBuf = Buffer.from(core);
const padLen = origBuf.length - coreBuf.length;
// Pad with a JS block comment to maintain exact byte length
const fullRepl = core + '/*' + 'x'.repeat(padLen - 4) + '*/';
const fullReplBuf = Buffer.from(fullRepl);

if (fullReplBuf.length !== origBuf.length) {
    console.error('ERROR: Replacement size mismatch:', fullReplBuf.length, '!=', origBuf.length);
    process.exit(99);
}
fullReplBuf.copy(exeBuf, patchIdx);

// Patch 2: Disable V8 code cache in SEA blob header
// The SEA blob flags are at file offset 0x5782666 (blob offset +4).
// Flags: bit 0 = kDisableExperimentalSEAWarning, bit 1 = kUseSnapshot, bit 2 = kUseCodeCache
// Clearing bit 2 forces V8 to recompile from the patched source instead of using
// the cached bytecode (which was compiled from the original source and will crash).
const SEA_FLAGS_OFFSET = 0x5782666;
exeBuf[SEA_FLAGS_OFFSET] = exeBuf[SEA_FLAGS_OFFSET] & 0xFB; // clear bit 2

// Write patched exe next to the original (needed for module resolution)
const splatDir = path.dirname(SPLAT_EXE);
const patchedExePath = path.join(splatDir, '_splat_patched.exe');
fs.writeFileSync(patchedExePath, exeBuf);

// --- Build the _S eval code ---
// Use forward slashes for paths (Node.js handles them fine on Windows)
const b1nPath = path.join(buildDir, baseName + '.b1n').split(path.sep).join('/');
const lstPath = path.join(buildDir, baseName + '.lst').split(path.sep).join('/');

// Delete existing outputs to prevent double-patching stale binaries
if (fs.existsSync(b1nPath)) fs.unlinkSync(b1nPath);
if (fs.existsSync(lstPath)) fs.unlinkSync(lstPath);

const evalCode = [
    'require("fs").writeFileSync("' + b1nPath + '",n.program)',
    'require("fs").writeFileSync("' + lstPath + '",n.list)',
].join(';');

// --- Compile ---
console.log('Compiling: ' + buildPath);
console.log('');

let exitCode = 0;
try {
    const output = execFileSync(patchedExePath, ['compile', buildPath], {
        cwd: buildDir,
        encoding: 'utf8',
        timeout: 60000,
        env: {
            ...process.env,
            MSYS_NO_PATHCONV: '1',
            '_S': evalCode,
        }
    });
    process.stdout.write(output);
} catch (err) {
    if (err.stdout) process.stdout.write(err.stdout);
    if (err.stderr) process.stderr.write(err.stderr);
    exitCode = err.status || 1;
}

// --- Post-compile binary patches ---
// Fix compiler bugs that can't be fixed in source.
if (fs.existsSync(b1nPath) && fs.existsSync(lstPath)) {
    const b1n = fs.readFileSync(b1nPath);
    let patchCount = 0;

    // === Patch A: Fix Error 54 in __HMI_event_task ===
    // Compiler generates tight polling loop without YieldTask.
    // Redirect GoIfXEQ target 2 bytes earlier to include existing YieldTask.
    const hmiPattern = Buffer.from([0x4A, 0x04, 0xF6, 0x13, 0x86, 0xFF]);
    const hmiIdx = b1n.indexOf(hmiPattern);
    if (hmiIdx >= 0) {
        const targetOffset = hmiIdx + 6;
        const oldTarget = (b1n[targetOffset] << 8) | b1n[targetOffset + 1];
        const newTarget = oldTarget - 2;
        b1n[targetOffset] = (newTarget >> 8) & 0xFF;
        b1n[targetOffset + 1] = newTarget & 0xFF;
        console.log('  Patch A: __HMI_event_task Error 54 fix (0x' +
            oldTarget.toString(16).toUpperCase() + ' -> 0x' +
            newTarget.toString(16).toUpperCase() + ')');
        patchCount++;
    }

    // === Patch C: Fix __HMI_delete_ev_char displaced ComRx_ReadOne ===
    // The compiler displaces ComRx_ReadOne (F6 16, 2 bytes) before the
    // __HMI_delete_ev_char label. Since 2-byte displacements land on the
    // next instruction boundary, Patch B doesn't detect them as misaligned.
    // But Branch Target 0 jumps to the label (past the ComRx_ReadOne),
    // so the RX buffer byte is never deleted, causing the event task to
    // loop forever on stale data and ignore all subsequent button events.
    //
    // Fix: Find the first Target entry after the Branch instruction in the
    // event task (Target 0 = __HMI_delete_ev_char) and subtract 2 to
    // include the displaced ComRx_ReadOne.
    if (hmiIdx >= 0) {
        // The Branch instruction (0x08) follows ComRx_StrFind in the event task.
        // Search forward from the event task pattern for: F6 2F xx 08
        let branchIdx = -1;
        for (let s = hmiIdx; s < hmiIdx + 40 && s < b1n.length - 3; s++) {
            if (b1n[s] === 0xF6 && b1n[s + 1] === 0x2F && b1n[s + 3] === 0x08) {
                branchIdx = s + 3; // points to the 0x08 (Branch opcode)
                break;
            }
        }
        if (branchIdx >= 0) {
            // Target 0 is the 2 bytes immediately after the Branch opcode
            const t0Offset = branchIdx + 1;
            const oldT0 = (b1n[t0Offset] << 8) | b1n[t0Offset + 1];
            const newT0 = oldT0 - 2;
            // Verify: the 2 bytes before the old target should be F6 16 (ComRx_ReadOne)
            const checkOffset = newT0 + 1; // +1 for header
            if (b1n[checkOffset] === 0xF6 && b1n[checkOffset + 1] === 0x16) {
                b1n[t0Offset] = (newT0 >> 8) & 0xFF;
                b1n[t0Offset + 1] = newT0 & 0xFF;
                console.log('  Patch C: __HMI_delete_ev_char fix (0x' +
                    oldT0.toString(16).toUpperCase() + ' -> 0x' +
                    newT0.toString(16).toUpperCase() + ')');
                patchCount++;
            } else {
                console.log('  Patch C: SKIPPED - ComRx_ReadOne (F6 16) not found at expected position');
            }
        } else {
            console.log('  Patch C: SKIPPED - Branch instruction not found in event task');
        }
    }

    // === Patch B: Fix ALL misaligned label branch targets ===
    // The SPLat compiler assigns label addresses as preceding_instr_addr + 2,
    // regardless of actual instruction length. When the preceding instruction is
    // 3+ bytes, the label points INTO that instruction. All branch instructions
    // that reference such labels encode the wrong target address.
    //
    // Strategy: Parse the listing to build a wrongAddr->correctAddr map,
    // then scan the binary and fix every branch target that hits a wrong address.

    const lstContent = fs.readFileSync(lstPath, 'utf8');
    const lstLines = lstContent.split(/\r?\n/);

    // Step 1: Parse listing to find all misaligned labels.
    //
    // The compiler bug: for a label defined BEFORE an instruction in source,
    // the compiler emits the instruction first, THEN places the label at
    // (instruction_start_addr + 2), regardless of instruction length.
    // So the label points INTO the instruction that should FOLLOW the label.
    //
    // In the listing, a misaligned label appears AFTER the instruction it
    // belongs to (the compiler reversed the order):
    //   XXXX:  F3 03 02 8C    |  NVSetPtr DIFManual    ← instruction (at addr XXXX)
    //   YYYY:                 |  DIFControllogic        ← label (at XXXX+2, WRONG)
    //
    // The correct label address should be XXXX (the instruction start), because
    // in source the label precedes the instruction. GoSub/GoTo should jump to
    // XXXX to execute the instruction, not to YYYY which lands mid-instruction.
    //
    // Detection: label_addr > 0 AND label_addr != preceding_instruction_addr
    //            AND label_addr = preceding_instruction_addr + 2
    // Fix: patch branch targets from label_addr to preceding_instruction_addr.

    const addrFixMap = new Map(); // wrongAddr -> correctAddr

    // Build a map of instruction addresses to their byte count (from first listing line only).
    // We only need the first line's byte count because:
    // - If it's > 2 bytes, the label at addr+2 is definitely misaligned
    // - Multi-line instructions (HMI data) always have > 2 bytes on their first line
    const instrByteCounts = new Map(); // instrAddr -> byte count on that line

    for (let i = 0; i < lstLines.length; i++) {
        const line = lstLines[i];
        // The NVEM0 data section appears after all code sections in the listing.
        // It shares the address space with CODESEG but lives in different memory.
        // Stop processing here — continuation lines of NV0Byte/NV0Ptr declarations
        // lack NV0 markers and create false instrByteCounts entries that corrupt
        // the address fix map (e.g. NV continuation at 0584 blocks the real fix
        // for backlight_initate_sub at 0585 → 0583).
        if (line.indexOf('NVEM0') >= 0) break;
        const instrMatch = line.match(/^([0-9A-Fa-f]{4}):\s+((?:[0-9A-Fa-f]{2}\s+)+)\|/);
        if (!instrMatch) continue;
        const addr = parseInt(instrMatch[1], 16);
        const byteCount = instrMatch[2].trim().split(/\s+/).length;
        // Only store first occurrence (instruction start, not continuation)
        if (!instrByteCounts.has(addr)) {
            instrByteCounts.set(addr, byteCount);
        }
    }

    // Find misaligned labels
    // The compiler places labels at preceding_instr_addr + 2 regardless of
    // instruction length. When the preceding instruction is >2 bytes, the label
    // falls INSIDE that instruction — an unambiguous misalignment.
    // For exactly 2-byte instructions, the label falls right after (no overlap),
    // which is handled by source-level duplicate instructions instead.
    for (let i = 0; i < lstLines.length; i++) {
        const line = lstLines[i];
        // Stop at NVEM0 section — NV labels share addresses with CODESEG
        if (line.indexOf('NVEM0') >= 0) break;
        const labelMatch = line.match(/^([0-9A-Fa-f]{4}):\s+\|/);
        if (!labelMatch) continue;

        const labelAddr = parseInt(labelMatch[1], 16);

        for (let offset = 1; offset <= 4; offset++) {
            const checkAddr = labelAddr - offset;
            const checkLen = instrByteCounts.get(checkAddr);
            if (checkLen !== undefined && checkLen > offset) {
                // Instruction at checkAddr extends past labelAddr
                addrFixMap.set(labelAddr, checkAddr);
                break;
            }
        }
    }

    if (addrFixMap.size > 0) {
        console.log('  Patch B: Found ' + addrFixMap.size + ' misaligned labels in listing');

        // Step 2: Parse ALL instructions from the listing and fix branch targets.
        // This is safer than scanning raw binary bytes (which could match data).
        // The listing tells us exactly where each instruction is and its hex encoding.
        //
        // For each listing line with hex bytes, we extract the instruction address and bytes.
        // We then check if any 2-byte sequence within the hex bytes encodes a misaligned
        // label address, and if so, fix it in the binary.
        //
        // However, not all 2-byte sequences are addresses - they could be data operands.
        // So we use opcode knowledge to find exactly which bytes are branch targets.
        //
        // Opcode -> offset of 2-byte big-endian target address within instruction:
        const targetOffsets = {
            // 3-byte: target at byte 1-2
            0x80: 1, 0x81: 1, 0x82: 1, 0x83: 1, 0x84: 1, 0x85: 1,
            0xA7: 1, 0xA9: 1, 0xAA: 1, 0xBE: 1, 0xBF: 1,
            // 4-byte: target at byte 2-3
            0x86: 2, 0x87: 2, 0x88: 2, 0x8A: 2, 0x8B: 2,
            0x30: 2, 0x31: 2, 0x32: 2, 0x33: 2, 0x34: 2,
            0x20: 2, 0x21: 2, 0x22: 2,
            // 5-byte: target at byte 3-4
            0x60: 3, 0x61: 3, 0x62: 3,
            0x26: 3, 0x28: 3, 0x2B: 3,
        };
        // Multi-byte opcode prefixes: second byte disambiguates
        // F6 xx: target at byte 2-3 (relative to F6)
        const f6Targets = { 0x1C: 2, 0x1D: 2, 0x1E: 2, 0x1F: 2 };
        // F4 xx: various
        const f4Targets = { 0x03: 2, 0x0F: 2, 0x07: 5 }; // LaunchTask, LaunchTaskX, LoopIfTiming
        // EF xx: add 1 to the inner opcode's offset
        // EF 60 -> target at 4, EF 62 -> target at 4, EF 28 -> target at 4, EF 8E -> target at 3

        const HEADER = 1; // 0x7E header byte in .b1n
        let branchFixCount = 0;

        for (let i = 0; i < lstLines.length; i++) {
            // Parse instruction lines: "ADDR:  HH HH HH ...   |  mnemonic"
            // IMPORTANT: Skip continuation lines (no mnemonic after |) to avoid
            // corrupting data bytes inside multi-byte #HMI instructions.
            const m = lstLines[i].match(/^([0-9A-Fa-f]{4}):\s+((?:[0-9A-Fa-f]{2}\s+)+)\|\s+\S/);
            if (!m) continue;

            const instrAddr = parseInt(m[1], 16);
            const hexBytes = m[2].trim().split(/\s+/).map(h => parseInt(h, 16));
            if (hexBytes.length < 2) continue;

            let tOff = -1; // offset of target address within instruction

            const opcode = hexBytes[0];
            if (opcode === 0xEF && hexBytes.length >= 2) {
                // EF prefix: inner opcode at byte 1
                const inner = hexBytes[1];
                if (targetOffsets[inner] !== undefined) {
                    tOff = targetOffsets[inner] + 1; // shift by 1 for EF prefix
                }
            } else if (opcode === 0xF6 && hexBytes.length >= 2) {
                if (f6Targets[hexBytes[1]] !== undefined) {
                    tOff = f6Targets[hexBytes[1]];
                }
            } else if (opcode === 0xF4 && hexBytes.length >= 2) {
                if (f4Targets[hexBytes[1]] !== undefined) {
                    tOff = f4Targets[hexBytes[1]];
                }
            } else if (targetOffsets[opcode] !== undefined) {
                tOff = targetOffsets[opcode];
            }

            if (tOff < 0 || tOff + 1 >= hexBytes.length) continue;

            // Extract target address from hex bytes
            const targetAddr = (hexBytes[tOff] << 8) | hexBytes[tOff + 1];
            const correctAddr = addrFixMap.get(targetAddr);
            if (correctAddr !== undefined) {
                const binPos = instrAddr + HEADER + tOff;
                if (binPos + 1 < b1n.length) {
                    b1n[binPos] = (correctAddr >> 8) & 0xFF;
                    b1n[binPos + 1] = correctAddr & 0xFF;
                    branchFixCount++;
                }
            }
        }

        // Step 3: Fix Target table entries (used by Branch/BranchR/BranchM/BranchJ).
        // Format in listing: "XXXX:  HH HH    |   Target  labelName"
        for (let i = 0; i < lstLines.length; i++) {
            const m = lstLines[i].match(/^([0-9A-Fa-f]{4}):\s+([0-9A-Fa-f]{2})\s+([0-9A-Fa-f]{2})\s+\|.*Target/i);
            if (!m) continue;
            const targetAddr = (parseInt(m[2], 16) << 8) | parseInt(m[3], 16);
            const correctAddr = addrFixMap.get(targetAddr);
            if (correctAddr !== undefined) {
                const binPos = parseInt(m[1], 16) + HEADER;
                if (binPos + 1 < b1n.length) {
                    b1n[binPos] = (correctAddr >> 8) & 0xFF;
                    b1n[binPos + 1] = correctAddr & 0xFF;
                    branchFixCount++;
                }
            }
        }

        if (branchFixCount > 0) {
            console.log('  Patch B: Fixed ' + branchFixCount + ' branch targets across ' + addrFixMap.size + ' misaligned labels');
            patchCount += branchFixCount;
        } else {
            console.log('  Patch B: No branch targets needed fixing (labels may be dormant)');
        }
    }

    if (patchCount > 0) {
        fs.writeFileSync(b1nPath, b1n);
    }
}

// --- Report results ---
const b1nExists = fs.existsSync(b1nPath);
const lstExists = fs.existsSync(lstPath);

if (b1nExists) {
    const b1nStat = fs.statSync(b1nPath);
    // Only report if the file was freshly written (within last 30 seconds)
    if (Date.now() - b1nStat.mtimeMs < 30000) {
        console.log('');
        console.log('  Binary:  ' + b1nPath + ' (' + b1nStat.size + ' bytes)');
        if (lstExists) {
            const lstStat = fs.statSync(lstPath);
            if (Date.now() - lstStat.mtimeMs < 30000) {
                console.log('  Listing: ' + lstPath + ' (' + lstStat.size + ' bytes)');
            }
        }
        console.log('  BUILD SUCCESS');
    }
} else if (exitCode === 0) {
    // Compilation reported success but no output file - something went wrong with the hook
    console.error('');
    console.error('WARNING: Compilation succeeded but no binary output was produced.');
    console.error('The eval hook may have failed. Check _S env var.');
}

// --- Cleanup ---
try { fs.unlinkSync(patchedExePath); } catch {}

if (exitCode !== 0) process.exit(exitCode);
