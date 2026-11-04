"""GDB-only observer of unchanged result-output functions, not a program patch.

ABI scope: x86-64 System V, reviewed vector/span entries or binary-pinned sites.
Memory is read, never written. Hardware execution breakpoints leave code bytes
unchanged. Large array payloads are temporary local files, not publication data.
"""
import hashlib
import json
import os
import re
import struct

import gdb


output_dir = os.environ["VALIDATION_ARRAY_DIR"]
config_path = os.environ["VALIDATION_ARRAY_CONFIG"]
with open(config_path, encoding="utf-8") as stream:
    config = json.load(stream)
if not os.path.realpath(output_dir).startswith("/tmp/"):
    raise RuntimeError("Array captures must stay under /tmp")
os.mkdir(output_dir)
captures = []
errors = []
exits = []
max_bytes = 64 * 1024 * 1024


def c_string(inferior, address):
    # Small bounded reads also work at a mapped-page boundary.
    value = bytearray()
    for offset in range(256):
        byte = bytes(inferior.read_memory(address + offset, 1))
        if byte == b"\0":
            return value.decode("utf-8", errors="strict")
        value.extend(byte)
    raise RuntimeError("Result name lacks a bounded NUL terminator")


class ArrayBoundary(gdb.Breakpoint):
    def __init__(self, entry):
        location = entry["location"]
        if not re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*(?:\+0x[0-9a-f]+)?", location):
            raise RuntimeError("Unsafe breakpoint expression")
        super().__init__("*" + location, type=gdb.BP_HARDWARE_BREAKPOINT,
                         internal=True)
        self.entry = entry
        self.symbol = location
        self.dtype = entry["dtype"]
        self.width = entry["width"]
        if (self.dtype, self.width) not in [("f64le", 8), ("f32le", 4),
                                          ("u32le", 4), ("i32le", 4)]:
            raise RuntimeError("Unsupported result scalar")
        self.silent = True

    def stop(self):
        try:
            inferior = gdb.selected_inferior()
            if inferior.architecture().name() != "i386:x86-64":
                raise RuntimeError("Unsupported result ABI")
            frame = gdb.newest_frame()
            register = lambda name: int(frame.read_register(name))
            abi = self.entry["abi"]
            if self.entry.get("instruction_hex"):
                expected = bytes.fromhex(self.entry["instruction_hex"])
                if bytes(inferior.read_memory(register("rip"), len(expected))) != expected:
                    raise RuntimeError("Pinned observation instruction changed")
            name = self.entry.get("name")
            if abi in ("vector", "frame_vector"):
                address = register("rdi") if abi == "vector" else register("rbp") + self.entry["frame_offset"]
                start, finish, capacity = struct.unpack("<QQQ", bytes(inferior.read_memory(address, 24)))
                if not start <= finish <= capacity:
                    raise RuntimeError("Invalid vector bounds")
                length = finish - start
                if name is None:
                    name = c_string(inferior, register("rsi"))
            elif abi in ("span_value", "pointer_count"):
                start, count = register("rdi"), register("rsi")
                length = count * self.width
                if name is None:
                    name = c_string(inferior, register("rdx"))
            elif abi == "span_reference":
                start, count = struct.unpack("<QQ", bytes(inferior.read_memory(register("rdi"), 16)))
                length = count * self.width
                name = c_string(inferior, register("rsi"))
            elif abi == "register_bounds":
                valid = {"rax", "rbx", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"}
                if not {self.entry["start_register"], self.entry["end_register"]} <= valid:
                    raise RuntimeError("Unsupported pointer registers")
                start = register(self.entry["start_register"])
                length = register(self.entry["end_register"]) - start
            else:
                raise RuntimeError("Unsupported array ABI")
            if not (0 <= length <= max_bytes and length % self.width == 0):
                raise RuntimeError("Invalid or oversized array bounds")
            if not isinstance(name, str) or not name or len(name) > 255:
                raise RuntimeError("Invalid output name")
            filename = "array-%04d.%s" % (len(captures), self.dtype)
            digest = hashlib.sha256()
            with open(os.path.join(output_dir, filename), "xb") as stream:
                for offset in range(0, length, 1024 * 1024):
                    data = bytes(inferior.read_memory(
                        start + offset, min(1024 * 1024, length - offset)))
                    digest.update(data)
                    stream.write(data)
            captures.append({"name": name, "dtype": self.dtype,
                             "elements": length // self.width, "bytes": length,
                             "file": filename, "sha256": digest.hexdigest(),
                             "symbol": self.symbol, "boundary_spec": self.entry})
            return False
        except Exception as error:
            errors.append(type(error).__name__ + ": " + str(error))
            return True


def exited(event):
    exits.append(getattr(event, "exit_code", None))


gdb.events.exited.connect(exited)
for command in ["set pagination off", "set confirm off",
                "set print thread-events off", "set disable-randomization off",
                "set startup-with-shell off", "maintenance set worker-threads 1",
                "unset environment VALIDATION_ARRAY_DIR",
                "unset environment VALIDATION_ARRAY_CONFIG"]:
    gdb.execute(command, to_string=True)

try:
    entries = config["entries"]
    symbols = [entry["location"] for entry in entries]
    if not symbols or len(symbols) != len(set(symbols)) or len(symbols) > 4:
        raise RuntimeError("Unsupported result-boundary symbol set")
    # Hardware breakpoint capabilities and relocated PIE symbols are available
    # only after starting the native inferior. Stop at its first instruction,
    # before any benchmark initialization or computation.
    gdb.execute("starti", to_string=False)
    breakpoints = [ArrayBoundary(entry) for entry in entries]
    if any(point.pending for point in breakpoints):
        raise RuntimeError("Unresolved result boundary")
    gdb.execute("continue", to_string=False)
    if not exits:
        errors.append("Inferior stopped before normal exit")
except Exception as error:
    errors.append(type(error).__name__ + ": " + str(error))

with open(os.path.join(output_dir, "capture.json"), "x", encoding="utf-8") as stream:
    json.dump({"schema_version": 1, "gdb_version": gdb.VERSION,
               "mechanism": "hardware entry breakpoint and read-only memory capture",
               "captures": captures, "errors": errors, "exit_codes": exits},
              stream, indent=2)
    stream.write("\n")
if errors or exits != [0]:
    gdb.execute("quit 86")
