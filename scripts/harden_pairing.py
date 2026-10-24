from pathlib import Path

path = Path('upstream/WorkSlop/MainMenuView.swift')
text = path.read_text(encoding='utf-8')

old_type = 'allowedContentTypes: [.propertyList]'
if old_type not in text:
    raise SystemExit('Could not find original .propertyList importer filter')
text = text.replace(old_type, 'allowedContentTypes: [.item]', 1)

start = text.find('    private func importPairing(from url: URL) -> String? {')
end_marker = '\n    }\n}\n\n// MARK: - About / risks / how-to'
end = text.find(end_marker, start)
if start == -1 or end == -1:
    raise SystemExit('Could not locate importPairing function')

replacement = '''    private func importPairing(from url: URL) -> String? {
        // Accept any Files/iCloud item here. The actual security check is the
        // pairing-record structure below, not the filename extension or UTType.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var coordinatedError: NSError?
        var importedData: Data?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatedError) { readableURL in
            importedData = try? Data(contentsOf: readableURL, options: [.mappedIfSafe])
        }

        guard let data = importedData else {
            if let coordinatedError {
                return "Không thể đọc tệp pairing: \\(coordinatedError.localizedDescription)"
            }
            return "Không thể đọc tệp pairing. Hãy lưu tệp vào Tệp hoặc Trên iPhone rồi thử lại."
        }

        guard let format = PairingStore.format(of: data) else {
            return PairingStore.diagnose(data) + " Không có dữ liệu nào được lưu."
        }

        do {
            try PairingStore.save(data)
            status.pairingChanged()
            switch format {
            case .legacy:
                return "Đã nhập pairing file (định dạng lockdown)."
            case .remotePairing:
                return "Đã nhập pairing file (RemotePairing iOS 17+)."
            }
        } catch {
            return "Không thể lưu pairing file: \\(error.localizedDescription)"
        }
    }'''

text = text[:start] + replacement + text[end + len('\n    }'):]
path.write_text(text, encoding='utf-8')

assert 'allowedContentTypes: [.item]' in text
assert 'NSFileCoordinator()' in text
assert 'pathExtension.lowercased() == "plist"' not in text
print('Pairing importer hardened successfully')
