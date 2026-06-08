from pathlib import Path

path = Path(__file__).resolve().parent / "install-core.ps1"
bom = b"\xEF\xBB\xBF"

data = path.read_bytes()

while data.startswith(bom):
    data = data[len(bom):]

text = data.decode("utf-8")

# 可选：移除文件开头空行
text = text.lstrip("\r\n")

text = text.replace("\r\n", "\n").replace("\r", "\n")
text = text.replace("\n", "\r\n")

path.write_bytes(bom + text.encode("utf-8"))

print("OK: normalize install-core.ps1 to UTF-8 with BOM and CRLF line endings")