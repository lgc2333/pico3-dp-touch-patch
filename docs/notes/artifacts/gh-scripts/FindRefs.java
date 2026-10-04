import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.Listing;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceManager;
import ghidra.util.task.ConsoleTaskMonitor;

import java.util.LinkedHashSet;
import java.util.Set;

public class FindRefs extends GhidraScript {
    @Override
    public void run() throws Exception {
        FunctionManager fm = currentProgram.getFunctionManager();
        ReferenceManager rm = currentProgram.getReferenceManager();
        Listing listing = currentProgram.getListing();
        DecompInterface dec = new DecompInterface();
        dec.openProgram(currentProgram);
        ConsoleTaskMonitor mon = new ConsoleTaskMonitor();

        Set<Function> funcs = new LinkedHashSet<Function>();
        for (String a : getScriptArgs()) {
            Address addr = toAddr(a);
            ghidra.program.model.symbol.ReferenceIterator refs = rm.getReferencesTo(addr);
            int n = 0;
            while (refs.hasNext()) { n++; refs.next(); }
            println("=== refs to " + addr + " : " + n);
            refs = rm.getReferencesTo(addr);
            while (refs.hasNext()) {
                Reference r = refs.next();
                Address from = r.getFromAddress();
                Function f = fm.getFunctionContaining(from);
                Instruction ins = listing.getInstructionAt(from);
                println("   from " + from + "  " + r.getReferenceType()
                        + "  func=" + (f == null ? "?" : f.getName() + "@" + f.getEntryPoint())
                        + "  ins=" + (ins == null ? "?" : ins.toString()));
                if (f != null) funcs.add(f);
            }
        }
        println("\n\n########## decompiling " + funcs.size() + " functions");
        for (Function f : funcs) {
            println("\n########## " + f.getName() + " @ " + f.getEntryPoint()
                    + " size=" + f.getBody().getNumAddresses());
            DecompileResults res = dec.decompileFunction(f, 300, mon);
            if (res != null && res.decompileCompleted()) {
                println(res.getDecompiledFunction().getC());
            } else {
                println("  <fail>");
            }
        }
    }
}
