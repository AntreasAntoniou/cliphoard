"""Export the shipping Mac taxonomy without reading owner preferences."""
from pathlib import Path
import re
import subprocess
import tempfile

root=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='cliphoard-tag-catalog-') as directory:
    temporary=Path(directory)
    hashing = re.search(r'struct HashingEmbedder: TextEmbedder \{(.*?)\n\}\n', (root/'Sources/Cliphoard/Search/DeepSearch.swift').read_text(), re.S)[1]
    (temporary/'Hashing.swift').write_text('import Foundation\nstruct HashingEmbedder {' + hashing + '\n}\n')
    (temporary/'Reference.swift').write_text('''import Foundation
@main struct Reference {
 static func main() throws {
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
  FileHandle.standardOutput.write(try encoder.encode(TagBaskets.builtIn))
 }
}
''')
    subprocess.run(['/usr/bin/swiftc',str(root/'Sources/Cliphoard/Search/TagBaskets.swift'),str(temporary/'Hashing.swift'),str(temporary/'Reference.swift'),'-o',str(temporary/'reference')],check=True)
    output=subprocess.check_output([str(temporary/'reference')])
    destination=root/'ports/windows/Cliphoard.Windows/TagBaskets.json'
    destination.write_bytes(output+b'\n')
print('Exported the 12 shipping Mac tag baskets')
