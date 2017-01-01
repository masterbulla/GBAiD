module gbaid.gba.timer;

import gbaid.util;

import gbaid.gba.memory;
import gbaid.gba.interrupt;

public class Timers {
    private IoRegisters* ioRegisters;
    private InterruptHandler interruptHandler;
    mixin privateFields!(ushort, "reloadValue", 0, 4);
    mixin privateFields!(int, "control", 0, 4);
    mixin privateFields!(int, "subTicks", 0, 4);
    mixin privateFields!(ushort, "ticks", 0, 4);

    public this(IoRegisters* ioRegisters, InterruptHandler interruptHandler) {
        this.ioRegisters = ioRegisters;
        this.interruptHandler = interruptHandler;

        ioRegisters.setReadMonitor!0x100(&onRead!0);
        ioRegisters.setReadMonitor!0x104(&onRead!1);
        ioRegisters.setReadMonitor!0x108(&onRead!2);
        ioRegisters.setReadMonitor!0x10C(&onRead!3);

        ioRegisters.setPostWriteMonitor!0x100(&onPostWrite!0);
        ioRegisters.setPostWriteMonitor!0x104(&onPostWrite!1);
        ioRegisters.setPostWriteMonitor!0x108(&onPostWrite!2);
        ioRegisters.setPostWriteMonitor!0x10C(&onPostWrite!3);
    }

    public size_t emulate(size_t cycles) {
        auto shortCycles = cast(ushort) cycles;
        auto previousOverflows = updateTimer!0(shortCycles, 0);
        previousOverflows = updateTimer!1(shortCycles, previousOverflows);
        previousOverflows = updateTimer!2(shortCycles, previousOverflows);
        updateTimer!3(shortCycles, previousOverflows);
        return 0;
    }

    private int updateTimer(int timer)(ushort cycles, int previousOverflows) {
        // Check that the timer is enabled
        if (!control!timer.checkBit(7)) {
            return false;
        }
        // Check the ticking condition
        int newTicks = void;
        if (control!timer.checkBit(2)) {
            // Count-up timing: increment if the previous timer overflowed
            newTicks = previousOverflows;
        } else {
            // Update the sub-ticks according to the pre-scaler
            subTicks!timer += cycles;
            auto preScalerBase2Power = control!timer.getPreScalerBase2Power();
            // We tick for each completed sub-tick
            newTicks = subTicks!timer >> preScalerBase2Power;
            subTicks!timer &= (1 << preScalerBase2Power) - 1;
        }
        // Only tick if we need to
        if (newTicks <= 0) {
            return false;
        }
        // Check for an overflow
        auto ticksUntilOverflow = ushort.max - ticks!timer + 1;
        if (newTicks < ticksUntilOverflow) {
            // No overflow, just increment the tick counter
            ticks!timer += newTicks;
            return 0;
        }
        // If we overflow, start by consuming the new ticks to that overflow
        newTicks -= ticksUntilOverflow;
        // Reload the value and add any extra ticks past the overflows
        ticksUntilOverflow = ushort.max - reloadValue!timer + 1;
        ticks!timer = cast(ushort) (reloadValue!timer + newTicks % ticksUntilOverflow);
        // Trigger an IRQ on overflow if requested
        if (control!timer.checkBit(6)) {
            interruptHandler.requestInterrupt(InterruptSource.TIMER_0_OVERFLOW + timer);
        }
        // Return the first overflow plus any extra
        return 1 + newTicks / ticksUntilOverflow;
    }

    private void onRead(int timer)(IoRegisters* ioRegisters, int address, int shift, int mask, ref int value) {
        // Ignore reads that aren't on the counter
        if (!(mask & 0xFFFF)) {
            return;
        }
        // Write the tick count to the value
        value = value & ~mask | ticks!timer & mask;
    }

    private void onPostWrite(int timer)
            (IoRegisters* ioRegisters, int address, int shift, int mask, int oldTimer, int newTimer) {
        // Update the control and reload value
        reloadValue!timer = cast(ushort) (newTimer & 0xFFFF);
        control!timer = newTimer >>> 16;
        // Reset the timer if the enable bit goes from 0 to 1
        if (!oldTimer.checkBit(23) && newTimer.checkBit(23)) {
            subTicks!timer = 0;
            ticks!timer = reloadValue!timer;
        }
    }
}

private int getPreScalerBase2Power(int control) {
    final switch (control & 0b11) {
        case 0:
            return 0;
        case 1:
            return 6;
        case 2:
            return 8;
        case 3:
            return 10;
    }
}