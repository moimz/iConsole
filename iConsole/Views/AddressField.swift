import SwiftUI
import AppKit

// inPlayer inPlayerMac/Web/WebBrowserView.swift 의 주소칸에서 가져옴 (누르면 전체 고르기, 고쳐 쓰는 중엔 페이지 주소로 안 바꿈, Esc 되돌리기)
struct AddressField: NSViewRepresentable {
    let url: URL?
    let controller: AddressController
    let onSubmit: (String) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = SelectAllTextField()
        field.placeholderString = "주소 또는 검색어"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.delegate = context.coordinator
        field.stringValue = url?.absoluteString ?? ""
        controller.field = field
        controller.onSubmit = { [weak coordinator = context.coordinator] in coordinator?.submit(field) }
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSubmit = onSubmit
        if coordinator.url != url {
            coordinator.url = url
            coordinator.edited = false
        }
        if !coordinator.edited { coordinator.show(url?.absoluteString ?? "") }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSubmit: onSubmit) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onSubmit: (String) -> Void
        var url: URL?
        weak var field: NSTextField?
        /// 사용자가 글을 고쳤는지 (페이지가 바뀌거나 보내면 풀린다)
        var edited = false
        init(onSubmit: @escaping (String) -> Void) { self.onSubmit = onSubmit }

        func controlTextDidChange(_ notification: Notification) { edited = true }

        /// Esc: 고친 글을 버리고 페이지 주소로
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            edited = false
            show(url?.absoluteString ?? "")
            control.window?.makeFirstResponder(nil)
            return true
        }

        /// 칸에 글을 보인다 (포커스가 있어도)
        func show(_ text: String) {
            guard let field, field.stringValue != text else { return }
            if let editor = field.currentEditor() as? NSTextView {
                editor.string = text
                editor.selectAll(nil)
            }
            field.stringValue = text
        }

        @objc func submit(_ field: NSTextField) {
            guard !field.stringValue.isEmpty else { return }
            edited = false
            onSubmit(field.stringValue)
            field.window?.makeFirstResponder(nil)
        }
    }
}

/// 이동(→) 단추가 주소칸의 글을 보내게 잇는다
@MainActor
final class AddressController {
    weak var field: NSTextField?
    var onSubmit: (() -> Void)?

    func submit() { onSubmit?() }

    /// ⌘L: 주소칸에 초점 (글 전체가 골라진다)
    func focus() {
        guard let field else { return }
        field.window?.makeFirstResponder(field)
    }
}

/// 누르거나 Tab 으로 들어오면 글 전체를 고르는 글 칸
/// 바뀜 (2026-11-07): 검색 칸 → 글 칸
private final class SelectAllTextField: NSTextField {
    private var selectsOnMouseUp = false

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            selectsOnMouseUp = NSApp.currentEvent?.type == .leftMouseDown
            // 키보드로 들어온 때는 바로 (누른 때는 누르는 동안 커서가 놓이므로 뗀 뒤에)
            DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) }
        }
        return became
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // 처음 누른 때만 전체를 고른다 (이미 고치는 중에 누르면 커서 두기)
        if selectsOnMouseUp {
            selectsOnMouseUp = false
            currentEditor()?.selectAll(nil)
        }
    }
}

