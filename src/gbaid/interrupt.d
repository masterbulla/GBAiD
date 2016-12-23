module gbaid.interrupt;

import gbaid.memory;
import gbaid.cpu;
import gbaid.halt;
import gbaid.util;

public class InterruptHandler {
    private IoRegisters* ioRegisters;
    private ARM7TDMI processor;
    private HaltHandler haltHandler;

    public this(IoRegisters* ioRegisters, ARM7TDMI processor, HaltHandler haltHandler) {
        this.ioRegisters = ioRegisters;
        this.processor = processor;
        this.haltHandler = haltHandler;
        ioRegisters.setPreWriteMonitor!0x200(&onInterruptAcknowledgePreWrite);
        ioRegisters.setPostWriteMonitor!0x300(&onHaltRequestPostWrite);
    }

    public void requestInterrupt(int source) {
        if (!(ioRegisters.getUnMonitored!int(0x208) & 0b1)
                || !ioRegisters.getUnMonitored!short(0x200).checkBit(source)) {
            return;
        }
        int flags = ioRegisters.getUnMonitored!short(0x202);
        flags.setBit(source, 1);
        ioRegisters.setUnMonitored!short(0x202, cast(short) flags);
        processor.irq(true);
        haltHandler.softwareHalt(false);
    }

    private bool onInterruptAcknowledgePreWrite(IoRegisters* ioRegisters, int address, int shift, int mask, ref int value) {
        enum int acknowledgeMask = 0x3FFF0000;
        // Ignore a write outside the acknowledge mask
        if (!(mask & acknowledgeMask)) {
            return true;
        }
        // Mask out all but the bits of the interrupt acknowledge register
        int acknowledgeValue = value & acknowledgeMask;
        // Invert the mask to clear the bits of the interrupts being acknowledged, and merge with the lower half
        value = ioRegisters.getUnMonitored!int(0x200) & acknowledgeMask & ~acknowledgeValue | value & 0xFFFF;
        // Trigger another IRQ if the bit is still set and it is enabled
        processor.irq((value & (value << 16) & acknowledgeMask) != 0);
        return true;
    }

    private void onHaltRequestPostWrite(IoRegisters* ioRegisters, int address, int shift, int mask, int oldValue, int newValue) {
        if (checkBit(mask, 15)) {
            if (checkBit(newValue, 15)) {
                // TODO: implement stop
                assert (0);
            } else {
                haltHandler.softwareHalt(true);
            }
        }
    }
}

public static enum InterruptSource {
    LCD_VBLANK = 0,
    LCD_HBLANK = 1,
    LCD_VCOUNTER_MATCH = 2,
    TIMER_0_OVERFLOW = 3,
    TIMER_1_OVERFLOW = 4,
    TIMER_2_OVERFLOW = 5,
    TIMER_3_OVERFLOW = 6,
    SERIAL_COMMUNICATION = 7,
    DMA_0 = 8,
    DMA_1 = 9,
    DMA_2 = 10,
    DMA_3 = 11,
    KEYPAD = 12,
    GAMEPAK = 13
}
