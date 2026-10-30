import SwiftUI

struct ThemedPicker<T: Hashable>: View {
    let title: String
    let nilLabel: String
    let showsDividerAfterNil: Bool
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T?
    @Environment(\.retroTheme) private var retroTheme
    @Environment(\.isEnabled) private var isEnabled

    init(
        _ title: String,
        selection: Binding<T?>,
        nilLabel: String = "Preset default",
        showsDividerAfterNil: Bool = true,
        options: [T],
        label: @escaping (T) -> String
    ) {
        self.title = title
        self._selection = selection
        self.nilLabel = nilLabel
        self.showsDividerAfterNil = showsDividerAfterNil
        self.options = options
        self.label = label
    }

    static func currentText(
        for selection: T?,
        nilLabel: String = "Preset default",
        label: (T) -> String
    ) -> String {
        selection.map(label) ?? nilLabel
    }

    static func optionsWithNil(_ options: [T]) -> [T?] {
        [nil] + options.map { Optional.some($0) }
    }

    var body: some View {
        if retroTheme {
            HStack(spacing: 8) {
                Text(title)
                    .font(RetroFont.font())
                    .foregroundStyle(isEnabled ? RetroPalette.shadow : RetroPalette.bevelDark)
                Spacer(minLength: 8)
                Menu {
                    Button {
                        selection = nil
                    } label: {
                        if selection == nil {
                            Label(nilLabel, systemImage: "checkmark")
                        } else {
                            Text(nilLabel)
                        }
                    }
                    if showsDividerAfterNil { Divider() }
                    ForEach(options, id: \.self) { option in
                        Button {
                            selection = option
                        } label: {
                            if selection == option {
                                Label(label(option), systemImage: "checkmark")
                            } else {
                                Text(label(option))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 0) {
                        Text(Self.currentText(for: selection, nilLabel: nilLabel, label: label))
                            .font(RetroFont.font())
                            .foregroundStyle(
                                !isEnabled
                                    ? RetroPalette.bevelDark
                                    : (selection == nil ? RetroPalette.secondaryText : RetroPalette.shadow)
                            )
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .frame(minWidth: 110, alignment: .leading)
                            .background(RetroPalette.bevelLight)
                            .retroBevel(.sunken)
                        Text("▼")
                            .font(RetroFont.font())
                            .foregroundStyle(isEnabled ? RetroPalette.shadow : RetroPalette.bevelDark)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(RetroPalette.panel)
                            .retroBevel(.raised)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        } else {
            Picker(title, selection: $selection) {
                Text(nilLabel).tag(T?.none)
                if showsDividerAfterNil { Divider() }
                ForEach(options, id: \.self) { Text(label($0)).tag(T?.some($0)) }
            }
        }
    }
}

struct ThemedValuePicker<T: Hashable>: View {
    let title: String
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T
    @Environment(\.retroTheme) private var retroTheme
    @Environment(\.isEnabled) private var isEnabled

    init(
        _ title: String,
        selection: Binding<T>,
        options: [T],
        label: @escaping (T) -> String
    ) {
        self.title = title
        self._selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        if retroTheme {
            HStack(spacing: 8) {
                Text(title)
                    .font(RetroFont.font())
                    .foregroundStyle(isEnabled ? RetroPalette.shadow : RetroPalette.bevelDark)
                Spacer(minLength: 8)
                Menu {
                    ForEach(options, id: \.self) { option in
                        Button {
                            selection = option
                        } label: {
                            if selection == option {
                                Label(label(option), systemImage: "checkmark")
                            } else {
                                Text(label(option))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 0) {
                        Text(label(selection))
                            .font(RetroFont.font())
                            .foregroundStyle(isEnabled ? RetroPalette.shadow : RetroPalette.bevelDark)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .frame(minWidth: 110, alignment: .leading)
                            .background(RetroPalette.bevelLight)
                            .retroBevel(.sunken)
                        Text("▼")
                            .font(RetroFont.font())
                            .foregroundStyle(isEnabled ? RetroPalette.shadow : RetroPalette.bevelDark)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(RetroPalette.panel)
                            .retroBevel(.raised)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        } else {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
        }
    }
}

struct ThemedRadioGroup<T: Hashable>: View {
    let title: String
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T
    @Environment(\.retroTheme) private var retroTheme
    @Environment(\.isEnabled) private var isEnabled

    init(
        _ title: String,
        selection: Binding<T>,
        options: [T],
        label: @escaping (T) -> String
    ) {
        self.title = title
        self._selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        if retroTheme {
            HStack(alignment: .top, spacing: 10) {
                Text(title)
                    .font(RetroFont.font())
                    .foregroundStyle(isEnabled ? RetroPalette.shadow : RetroPalette.bevelDark)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(options, id: \.self) { option in
                        let selected = (selection == option)
                        Button {
                            selection = option
                        } label: {
                            HStack(spacing: 6) {
                                Text(selected ? "•" : " ")
                                    .font(RetroFont.font())
                                    .foregroundStyle(isEnabled ? RetroPalette.shadow : RetroPalette.bevelDark)
                                    .frame(width: 16, height: 16)
                                    .background(RetroPalette.bevelLight)
                                    .retroBevel(.sunken)
                                Text(label(option))
                                    .font(RetroFont.font())
                                    .foregroundStyle(isEnabled ? RetroPalette.shadow : RetroPalette.bevelDark)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.radioGroup)
        }
    }
}

struct ThemedSegmented<T: Hashable>: View {
    let title: String
    let showsTitle: Bool
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T
    @Environment(\.retroTheme) private var retroTheme
    @Environment(\.isEnabled) private var isEnabled

    init(
        _ title: String,
        showsTitle: Bool = true,
        selection: Binding<T>,
        options: [T],
        label: @escaping (T) -> String
    ) {
        self.title = title
        self.showsTitle = showsTitle
        self._selection = selection
        self.options = options
        self.label = label
    }

    static func isSelected(_ option: T, selection: T) -> Bool {
        option == selection
    }

    var body: some View {
        if retroTheme {
            HStack(spacing: 8) {
                if showsTitle {
                    Text(title)
                        .font(RetroFont.font())
                        .foregroundStyle(isEnabled ? RetroPalette.shadow : RetroPalette.bevelDark)
                    Spacer(minLength: 8)
                }
                HStack(spacing: 4) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            selection = option
                        } label: {
                            Text(label(option))
                                .frame(maxWidth: showsTitle ? nil : .infinity)
                        }
                        .buttonStyle(
                            RetroButtonStyle(
                                kind: .text,
                                isSelected: Self.isSelected(option, selection: selection)
                            )
                        )
                    }
                }
            }
        } else if showsTitle {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
        } else {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

struct ThemedForm<Content: View>: View {
    private let content: Content
    @Environment(\.retroTheme) private var retroTheme

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if retroTheme {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RetroPalette.panel)
        } else {
            Form {
                content
            }
            .formStyle(.grouped)
        }
    }
}

private struct RetroSectionLayout: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                if index > 0 {
                    RetroPalette.bevelDark
                        .frame(height: 1)
                }
                child
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct ThemedSection<Content: View>: View {
    let title: String?
    private let content: Content
    @Environment(\.retroTheme) private var retroTheme

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        if retroTheme {
            VStack(alignment: .leading, spacing: 4) {
                if let title {
                    Text(title)
                        .font(RetroFont.font())
                        .foregroundStyle(RetroPalette.shadow)
                }
                _VariadicView.Tree(RetroSectionLayout()) {
                    content
                }
                .background(RetroPalette.panel)
                .retroBevel(.sunken)
            }
        } else if let title {
            Section(title) {
                content
            }
        } else {
            Section {
                content
            }
        }
    }
}

struct ThemedTextField: View {
    let title: String
    @Binding var text: String
    var prompt: String?
    @Environment(\.retroTheme) private var retroTheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if retroTheme {
            HStack(spacing: 8) {
                Text(title)
                    .font(RetroFont.font())
                    .foregroundStyle(isEnabled ? RetroPalette.shadow : RetroPalette.bevelDark)
                Spacer(minLength: 8)
                TextField("", text: $text)
                    .textFieldStyle(RetroTextFieldStyle())
                    .overlay(alignment: .leading) {
                        if text.isEmpty, let prompt {
                            Text(prompt)
                                .font(RetroFont.font())
                                .foregroundStyle(RetroPalette.secondaryText)
                                .padding(.leading, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(minWidth: 120, maxWidth: 200)
            }
        } else {
            TextField(title, text: $text, prompt: prompt.map { Text($0) })
        }
    }
}

struct ThemedNumberField: View {
    let title: String
    @Binding var value: Int
    @Environment(\.retroTheme) private var retroTheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if retroTheme {
            HStack(spacing: 8) {
                Text(title)
                    .font(RetroFont.font())
                    .foregroundStyle(isEnabled ? RetroPalette.shadow : RetroPalette.bevelDark)
                Spacer(minLength: 8)
                TextField("", value: $value, format: .number.grouping(.never))
                    .textFieldStyle(RetroTextFieldStyle())
                    .frame(minWidth: 90, maxWidth: 140)
            }
        } else {
            TextField(title, value: $value, format: .number.grouping(.never))
        }
    }
}

struct ThemedOptionalNumberField: View {
    let title: String
    @Binding var value: Int?
    @Environment(\.retroTheme) private var retroTheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if retroTheme {
            HStack(spacing: 8) {
                Text(title)
                    .font(RetroFont.font())
                    .foregroundStyle(isEnabled ? RetroPalette.shadow : RetroPalette.bevelDark)
                Spacer(minLength: 8)
                TextField("", value: $value, format: .number.grouping(.never))
                    .textFieldStyle(RetroTextFieldStyle())
                    .frame(minWidth: 90, maxWidth: 140)
            }
        } else {
            TextField(title, value: $value, format: .number.grouping(.never))
        }
    }
}

struct ThemedLabeledRow<Content: View>: View {
    let title: String
    private let content: Content
    @Environment(\.retroTheme) private var retroTheme
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        if retroTheme {
            HStack(alignment: .top, spacing: 8) {
                Text(title)
                    .font(RetroFont.font())
                    .foregroundStyle(isEnabled ? RetroPalette.shadow : RetroPalette.bevelDark)
                    .padding(.top, 2)
                Spacer(minLength: 8)
                content
            }
        } else {
            LabeledContent(title) {
                content
            }
        }
    }
}

struct RetroModalContainer<Content: View>: View {
    let title: String
    let width: CGFloat
    var onCancel: (() -> Void)?
    var onDefaultAction: (() -> Void)?
    private let content: Content
    @FocusState private var isFocused: Bool

    init(
        title: String,
        width: CGFloat,
        onCancel: (() -> Void)? = nil,
        onDefaultAction: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.width = width
        self.onCancel = onCancel
        self.onDefaultAction = onDefaultAction
        self.content = content()
    }

    var body: some View {
        ZStack {
            RetroPalette.shadow.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    isFocused = true
                }
            RetroPanel(title: title) {
                content
            }
            .retroControls()
            .frame(maxWidth: width)
            .padding(16)
        }
        .focusSection()
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            DispatchQueue.main.async {
                isFocused = true
            }
        }
        .onExitCommand {
            onCancel?()
        }
        .onKeyPress(.escape) {
            onCancel?()
            return .handled
        }
        .onKeyPress(.return) {
            onDefaultAction?()
            return .handled
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .space], phases: [.down, .repeat]) { _ in
            .handled
        }
    }
}

struct RetroScrollableMessage: View {
    static let defaultMaxHeight: CGFloat = 240

    let text: String
    var maxHeight: CGFloat = Self.defaultMaxHeight

    var body: some View {
        ViewThatFits(in: .vertical) {
            messageText
            ScrollView {
                messageText
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxHeight: maxHeight)
    }

    private var messageText: some View {
        Text(text)
            .font(RetroFont.font())
            .foregroundStyle(RetroPalette.shadow)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RetroSpinner: View {
    private static let frames = ["|", "/", "-", "\\"]
    @State private var index = 0

    var body: some View {
        HStack(spacing: 4) {
            PixelSymbol("hourglass", color: RetroPalette.yellow, pointSize: 16, scale: 1)
            Text(Self.frames[index % Self.frames.count])
                .font(RetroFont.font())
                .foregroundStyle(RetroPalette.highlightText)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(RetroPalette.shadow)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                index = (index + 1) % Self.frames.count
            }
        }
    }
}
