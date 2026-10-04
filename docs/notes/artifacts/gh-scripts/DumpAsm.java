import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.listing.Instruction;

public class DumpAsm extends GhidraScript {
    @Override
    public void run() throws Exception {
        FunctionManager fm = currentProgram.getFunctionManager();
        for (String a : getScriptArgs()) {
            Address addr = toAddr(a);
            Function f = fm.getFunctionContaining(addr);
            if (f == null) { println("no function at " + a); continue; }
            println("### " + f.getName() + " @ " + f.getEntryPoint());
            Instruction ins = currentProgram.getListing().getInstructionAt(f.getEntryPoint());
            Address end = f.getBody().getMaxAddress();
            while (ins != null && ins.getAddress().compareTo(end) <= 0) {
                StringBuilder sb = new StringBuilder();
                for (byte b : ins.getBytes()) sb.append(String.format("%02x ", b));
                println(String.format("%s  %-24s %s", ins.getAddress(), sb.toString().trim(),
                        ins.toString()));
                ins = ins.getNext();
            }
        }
    }
}
