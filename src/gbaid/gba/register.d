module gbaid.gba.register;

import gbaid.util;

public enum Set {
    ARM = 0,
    THUMB = 1
}

public enum Mode {
    USER = 16,
    FIQ = 17,
    IRQ = 18,
    SUPERVISOR = 19,
    ABORT = 23,
    UNDEFINED = 27,
    SYSTEM = 31
}

public enum Register {
    R0 = 0,
    R1 = 1,
    R2 = 2,
    R3 = 3,
    R4 = 4,
    R5 = 5,
    R6 = 6,
    R7 = 7,
    R8 = 8,
    R9 = 9,
    R10 = 10,
    R11 = 11,
    R12 = 12,
    SP = 13,
    LR = 14,
    PC = 15,
}

public enum CPSRFlag {
    N = 31,
    Z = 30,
    C = 29,
    V = 28,
    I = 7,
    F = 6,
    T = 5,
}

public struct Registers {
    private immutable size_t[REGISTER_LOOKUP_LENGTH] registerIndices = createRegisterLookupTable();
    private int[REGISTER_COUNT] registers;
    private int cpsrRegister;
    private int[1 << MODE_BITS] spsrRegisters;
    private bool modifiedPC = false;

    @property public Mode mode() {
        return cast(Mode) (cpsrRegister & 0x1F);
    }

    @property public Set instructionSet() {
        return cast(Set) cpsrRegister.getBit(CPSRFlag.T);
    }

    public int get(int register) {
        return get(mode, register);
    }

    public int get(Mode mode, int register) {
        return registers[registerIndices[(mode & 0xF) << REGISTER_BITS | register]];
    }

    public int getPC() {
        return registers[Register.PC];
    }

    public int getCPSR() {
        return cpsrRegister;
    }

    public int getSPSR() {
        return getSPSR(mode);
    }

    public int getSPSR(Mode mode) {
        if (mode == Mode.SYSTEM || mode == Mode.USER) {
            throw new Exception("The SPSR register does not exist in the system and user modes");
        }
        return spsrRegisters[mode & 0xF];
    }

    public void set(int register, int value) {
        set(mode, register, value);
    }

    public void set(Mode mode, int register, int value) {
        registers[registerIndices[(mode & 0xF) << REGISTER_BITS | register]] = value;
        if (register == Register.PC) {
            modifiedPC = true;
        }
    }

    public void setPC(int value) {
        registers[Register.PC] = value;
        modifiedPC = true;
    }

    public void setCPSR(int value) {
        cpsrRegister = value;
    }

    public void setSPSR(int value) {
        setSPSR(mode, value);
    }

    public void setSPSR(Mode mode, int value) {
        if (mode == Mode.SYSTEM || mode == Mode.USER) {
            throw new Exception("The SPSR register does not exist in the system and user modes");
        }
        spsrRegisters[mode & 0xF] = value;
    }

    public int getFlag(CPSRFlag flag) {
        return cpsrRegister.getBit(flag);
    }

    public void setFlag(CPSRFlag flag, int b) {
        cpsrRegister.setBit(flag, b);
    }

    public void setApsrFlags(int n, int z) {
        auto newFlags = (n << 3) & 0b1000 | (z << 2) & 0b0100;
        cpsrRegister = cpsrRegister & 0x3FFFFFFF | (newFlags << 28);
    }

    public void setApsrFlags(int n, int z, int c) {
        auto newFlags = (n << 3) & 0b1000 | (z << 2) & 0b0100 | (c << 1) & 0b0010;
        cpsrRegister = cpsrRegister & 0x1FFFFFFF | (newFlags << 28);
    }

    public void setApsrFlags(int n, int z, int c, int v) {
        auto newFlags = (n << 3) & 0b1000 | (z << 2) & 0b0100 | (c << 1) & 0b0010 | v & 0b0001;
        cpsrRegister = cpsrRegister & 0x0FFFFFFF | (newFlags << 28);
    }

    public void setApsrFlagsPacked(int nzcv) {
        cpsrRegister = cpsrRegister & 0x0FFFFFFF | (nzcv << 28);
    }

    public void setMode(Mode mode) {
        cpsrRegister.setBits(0, 4, mode);
    }

    public void incrementPC() {
        final switch (instructionSet) {
            case Set.ARM:
                registers[Register.PC] = (registers[Register.PC] & ~3) + 4;
                break;
            case Set.THUMB:
                registers[Register.PC] = (registers[Register.PC] & ~1) + 2;
                break;
        }
    }

    public int getExecutedPC() {
        final switch (instructionSet) {
            case Set.ARM:
                return registers[Register.PC] - 8;
            case Set.THUMB:
                return registers[Register.PC] - 4;
        }
    }

    public bool wasPCModified() {
        auto value = modifiedPC;
        modifiedPC = false;
        return value;
    }

    public int applyShift(bool registerShift)(int shiftType, ubyte shift, int op, out int carry) {
        final switch (shiftType) {
            // LSL
            case 0:
                static if (registerShift) {
                    if (shift == 0) {
                        carry = getFlag(CPSRFlag.C);
                        return op;
                    } else if (shift < 32) {
                        carry = op.getBit(32 - shift);
                        return op << shift;
                    } else if (shift == 32) {
                        carry = op & 0b1;
                        return 0;
                    } else {
                        carry = 0;
                        return 0;
                    }
                } else {
                    if (shift == 0) {
                        carry = getFlag(CPSRFlag.C);
                        return op;
                    } else {
                        carry = op.getBit(32 - shift);
                        return op << shift;
                    }
                }
            // LSR
            case 1:
                static if (registerShift) {
                    if (shift == 0) {
                        carry = getFlag(CPSRFlag.C);
                        return op;
                    } else if (shift < 32) {
                        carry = op.getBit(shift - 1);
                        return op >>> shift;
                    } else if (shift == 32) {
                        carry = op.getBit(31);
                        return 0;
                    } else {
                        carry = 0;
                        return 0;
                    }
                } else {
                    if (shift == 0) {
                        carry = op.getBit(31);
                        return 0;
                    } else {
                        carry = op.getBit(shift - 1);
                        return op >>> shift;
                    }
                }
            // ASR
            case 2:
                static if (registerShift) {
                    if (shift == 0) {
                        carry = getFlag(CPSRFlag.C);
                        return op;
                    } else if (shift < 32) {
                        carry = op.getBit(shift - 1);
                        return op >> shift;
                    } else {
                        carry = op.getBit(31);
                        return carry ? 0xFFFFFFFF : 0;
                    }
                } else {
                    if (shift == 0) {
                        carry = op.getBit(31);
                        return carry ? 0xFFFFFFFF : 0;
                    } else {
                        carry = op.getBit(shift - 1);
                        return op >> shift;
                    }
                }
            // ROR
            case 3:
                static if (registerShift) {
                    if (shift == 0) {
                        carry = getFlag(CPSRFlag.C);
                        return op;
                    } else if (shift & 0b11111) {
                        shift &= 0b11111;
                        carry = op.getBit(shift - 1);
                        return op.rotateRight(shift);
                    } else {
                        carry = op.getBit(31);
                        return op;
                    }
                } else {
                    if (shift == 0) {
                        // RRX
                        carry = op & 0b1;
                        return getFlag(CPSRFlag.C) << 31 | op >>> 1;
                    } else {
                        carry = op.getBit(shift - 1);
                        return op.rotateRight(shift);
                    }
                }
        }
    }

    public bool checkCondition(int condition) {
        final switch (condition) {
            case 0x0:
                // EQ
                return cpsrRegister.checkBit(CPSRFlag.Z);
            case 0x1:
                // NE
                return !cpsrRegister.checkBit(CPSRFlag.Z);
            case 0x2:
                // CS/HS
                return cpsrRegister.checkBit(CPSRFlag.C);
            case 0x3:
                // CC/LO
                return !cpsrRegister.checkBit(CPSRFlag.C);
            case 0x4:
                // MI
                return cpsrRegister.checkBit(CPSRFlag.N);
            case 0x5:
                // PL
                return !cpsrRegister.checkBit(CPSRFlag.N);
            case 0x6:
                // VS
                return cpsrRegister.checkBit(CPSRFlag.V);
            case 0x7:
                // VC
                return !cpsrRegister.checkBit(CPSRFlag.V);
            case 0x8:
                // HI
                return cpsrRegister.checkBit(CPSRFlag.C) && !cpsrRegister.checkBit(CPSRFlag.Z);
            case 0x9:
                // LS
                return !cpsrRegister.checkBit(CPSRFlag.C) || cpsrRegister.checkBit(CPSRFlag.Z);
            case 0xA:
                // GE
                return cpsrRegister.checkBit(CPSRFlag.N) == cpsrRegister.checkBit(CPSRFlag.V);
            case 0xB:
                // LT
                return cpsrRegister.checkBit(CPSRFlag.N) != cpsrRegister.checkBit(CPSRFlag.V);
            case 0xC:
                // GT
                return !cpsrRegister.checkBit(CPSRFlag.Z)
                        && cpsrRegister.checkBit(CPSRFlag.N) == cpsrRegister.checkBit(CPSRFlag.V);
            case 0xD:
                // LE
                return cpsrRegister.checkBit(CPSRFlag.Z)
                    || cpsrRegister.checkBit(CPSRFlag.N) != cpsrRegister.checkBit(CPSRFlag.V);
            case 0xE:
                // AL
                return true;
            case 0xF:
                // NV
                return false;
        }
    }

    debug (outputInstructions) {
        import std.stdio : writeln, writef, writefln;

        private enum size_t CPU_LOG_SIZE = 32;
        private CpuState[CPU_LOG_SIZE] cpuLog;
        private size_t logSize = 0;
        private size_t index = 0;

        public void logInstruction(int code, string mnemonic) {
            logInstruction(getExecutedPC(), code, mnemonic);
        }

        public void logInstruction(int address, int code, string mnemonic) {
            if (instructionSet == Set.THUMB) {
                code &= 0xFFFF;
            }
            cpuLog[index].mode = mode;
            cpuLog[index].address = address;
            cpuLog[index].code = code;
            cpuLog[index].mnemonic = mnemonic;
            cpuLog[index].set = instructionSet;
            foreach (i; 0 .. 16) {
                cpuLog[index].registers[i] = get(i);
            }
            cpuLog[index].cpsrRegister = cpsrRegister;
            if (mode != Mode.SYSTEM && mode != Mode.USER) {
                cpuLog[index].spsrRegister = getSPSR();
            }
            index = (index + 1) % CPU_LOG_SIZE;
            if (logSize < CPU_LOG_SIZE) {
                logSize++;
            }
        }

        public void dumpInstructions() {
            dumpInstructions(logSize);
        }

        public void dumpInstructions(size_t amount) {
            amount = amount > logSize ? logSize : amount;
            auto start = (logSize < CPU_LOG_SIZE ? 0 : index) + logSize - amount;
            if (amount > 1) {
                writefln("Dumping last %s instructions executed:", amount);
            }
            foreach (i; 0 .. amount) {
                cpuLog[(i + start) % CPU_LOG_SIZE].dump();
            }
        }

        private static struct CpuState {
            private Mode mode;
            private int address;
            private int code;
            private string mnemonic;
            private Set set;
            private int[16] registers;
            private int cpsrRegister;
            private int spsrRegister;

            private void dump() {
                writefln("%s", mode);
                // Dump register values
                foreach (i; 0 .. 4) {
                    writef("%-4s", cast(Register) (i * 4));
                    foreach (j; 0 .. 4) {
                        writef(" %08X", registers[i * 4 + j]);
                    }
                    writeln();
                }
                writef("CPSR %08X", cpsrRegister);
                if (mode != Mode.SYSTEM && mode != Mode.USER) {
                    writef(", SPSR %08X", spsrRegister);
                }
                writeln();
                // Dump instruction
                final switch (set) {
                    case Set.ARM:
                        writefln("%08X: %08X %s", address, code, mnemonic);
                        break;
                    case Set.THUMB:
                        writefln("%08X: %04X     %s", address, code, mnemonic);
                        break;
                }
                writeln();
            }
        }
    }
}

private enum REGISTER_COUNT = 31;
private enum REGISTER_BITS = 4;
private enum MODE_BITS = 4;
private enum REGISTER_LOOKUP_LENGTH = 1 << (MODE_BITS + REGISTER_BITS);

private size_t[] createRegisterLookupTable() {
    size_t[] table;
    table.length = REGISTER_LOOKUP_LENGTH;
    // For all modes: R0 - R15 = 0 - 15
    void setIndex(int mode, int register, size_t i) {
        table[(mode & 0xF) << REGISTER_BITS | register] = i;
    }
    size_t i = void;
    foreach (mode; 0 .. 1 << MODE_BITS) {
        i = 0;
        foreach (register; 0 .. 1 << REGISTER_BITS) {
            setIndex(mode, register, i++);
        }
    }
    // Except: R8_fiq - R14_fiq
    setIndex(Mode.FIQ, 8, i++);
    setIndex(Mode.FIQ, 9, i++);
    setIndex(Mode.FIQ, 10, i++);
    setIndex(Mode.FIQ, 11, i++);
    setIndex(Mode.FIQ, 12, i++);
    setIndex(Mode.FIQ, 13, i++);
    setIndex(Mode.FIQ, 14, i++);
    // Except: R13_svc - R14_svc
    setIndex(Mode.SUPERVISOR, 13, i++);
    setIndex(Mode.SUPERVISOR, 14, i++);
    // Except: R13_abt - R14_abt
    setIndex(Mode.ABORT, 13, i++);
    setIndex(Mode.ABORT, 14, i++);
    // Except: R13_irq - R14_irq
    setIndex(Mode.IRQ, 13, i++);
    setIndex(Mode.IRQ, 14, i++);
    // Except: R13_und - R14_und
    setIndex(Mode.UNDEFINED, 13, i++);
    setIndex(Mode.UNDEFINED, 14, i++);
    return table;
}
