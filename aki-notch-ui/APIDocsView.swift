// APIDocsView.swift — aki-notch-ui

import SwiftUI

// MARK: - API Documentation View

struct APIDocsView: View {
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Local Overlay API")
                                .font(.system(size: 18, weight: .bold))
                            Text(
                                "aki-notch-ui exposes a local HTTP server for external tools, scripts, or backends to drive the notch overlay UI."
                            )
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.apiDocsMarkdown, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                copied = false
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11))
                                Text(copied ? "Copied!" : "Copy")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(
                                        copied
                                            ? Color.green.opacity(0.15) : Color.white.opacity(0.06))
                            )
                            .foregroundStyle(copied ? .green : .secondary)
                        }
                        .buttonStyle(.plain)
                        .animation(.easeInOut(duration: 0.2), value: copied)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "network")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("http://127.0.0.1:47037")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(.top, 4)
                }

                Divider()

                // Endpoints
                apiEndpoint(
                    method: "GET",
                    path: "/health",
                    description: "Check if the overlay server is running.",
                    requestBody: nil,
                    responseExample: """
                        {"status": "ok", "port": 47037}
                        """
                )

                apiEndpoint(
                    method: "POST",
                    path: "/overlay",
                    description:
                        "Show a one-way notification card. The card appears, plays the typewriter animation, then auto-collapses after the configured duration.",
                    requestBody: """
                        {
                          "name": "Aki",
                          "name_color": "#7FD6FF",
                          "message": "Hello world!",
                          "image_base64": "<base64 PNG>",
                          "image_url": "https://...",
                          "accent_hex": "#7FD6FF",
                          "expanded": true
                        }
                        """,
                    responseExample: """
                        {"status": "updated"}
                        """,
                    notes:
                        "All fields except `message` are optional. `image_base64` takes precedence over `image_url`. Set `expanded` to `false` to skip the expand animation."
                )

                apiEndpoint(
                    method: "POST",
                    path: "/chat",
                    description:
                        "Show an interactive chat card and wait for the user's response. The HTTP connection stays open until the user answers or dismisses.",
                    requestBody: """
                        {
                          "name": "Aki",
                          "name_color": "#7FD6FF",
                          "message": "How are you?",
                          "image_base64": "<base64 PNG>",
                          "accent_hex": "#7FD6FF",
                          "proposed_answers": ["Good", "Meh", "Bad"]
                        }
                        """,
                    responseExample: """
                        {"status": "answered", "answer": "Good"}
                        """,
                    notes:
                        "`proposed_answers` is optional — if omitted, only the free-text input is shown. If the user dismisses without answering, `answer` is an empty string `\"\"`."
                )

                apiEndpoint(
                    method: "GET",
                    path: "/listen",
                    description:
                        "Long-poll for the next user-initiated message from the Compose panel (⌥Space). The connection stays open until the user sends a message.",
                    requestBody: nil,
                    responseExample: """
                        {"status": "received", "message": "Tell me a joke"}
                        """,
                    notes:
                        "Useful for building a \"push-to-talk\" workflow where the user initiates conversation."
                )

                apiEndpoint(
                    method: "POST",
                    path: "/collapse",
                    description: "Collapse (hide) the currently visible overlay card.",
                    requestBody: nil,
                    responseExample: """
                        {"status": "collapsed"}
                        """
                )

                apiEndpoint(
                    method: "POST",
                    path: "/clear",
                    description: "Dismiss all UI — overlay, chat, and compose.",
                    requestBody: nil,
                    responseExample: """
                        {"status": "cleared"}
                        """
                )

                Divider()

                // Usage tips
                SettingsSection(title: "USAGE TIPS") {
                    VStack(alignment: .leading, spacing: 10) {
                        tipRow(
                            icon: "terminal",
                            text: "Quick test from the terminal:"
                        )
                        Text(
                            "curl -X POST http://127.0.0.1:47037/overlay \\\n  -H 'Content-Type: application/json' \\\n  -d '{\"message\": \"Hello!\"}'"
                        )
                        .font(.system(size: 11, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .textSelection(.enabled)

                        tipRow(
                            icon: "arrow.left.arrow.right",
                            text:
                                "Use the built-in Characters tab for the full agent loop (triggers, memory, tools). Use this API when you want to drive the overlay from your own backend or scripts."
                        )

                        tipRow(
                            icon: "clock",
                            text:
                                "/chat and /listen are long-polling — the connection stays open until there's a response. Set an appropriate timeout on your HTTP client."
                        )
                    }
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private func apiEndpoint(
        method: String,
        path: String,
        description: String,
        requestBody: String?,
        responseExample: String,
        notes: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Method + path
            HStack(spacing: 8) {
                Text(method)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(methodColor(method).opacity(0.15))
                    .foregroundStyle(methodColor(method))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(path)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
            }

            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if let body = requestBody {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Request body")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Text(body)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .textSelection(.enabled)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Response")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text(responseExample)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)
            }

            if let notes {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(notes)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        }
    }

    private func methodColor(_ method: String) -> Color {
        switch method {
        case "GET": return .green
        case "POST": return .blue
        case "DELETE": return .red
        default: return .primary
        }
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Copyable API Markdown

    private static let apiDocsMarkdown: String = """
        # Aki Notch UI — API Reference

        Base URL: `http://127.0.0.1:47037`

        ---

        ## `GET /health`

        Health check endpoint.

        **Response**

        ```json
        { "status": "ok", "port": 47037 }
        ```

        ---

        ## `POST /overlay`

        Show a one-way notification card. The card appears, plays the typewriter animation, then auto-collapses after the configured duration.

        **Request Body**

        | Field          | Type     | Required | Description                                                        |
        | -------------- | -------- | -------- | ------------------------------------------------------------------ |
        | `message`      | `string` | **yes**  | The text to display.                                               |
        | `name`         | `string` | no       | Speaker name, displayed as a colored prefix.                       |
        | `name_color`   | `string` | no       | Hex color for the name prefix (e.g. `"#7FD6FF"`).                  |
        | `image_base64` | `string` | no       | Base-64 encoded image data.                                        |
        | `image_url`    | `string` | no       | URL of an image to load. Ignored if `image_base64` is set.         |
        | `accent_hex`   | `string` | no       | Accent color hex (default `"#7FD6FF"`).                            |
        | `expanded`     | `bool`   | no       | Whether to show the card (default `true`).                         |

        **Example**

        ```bash
        curl -X POST http://127.0.0.1:47037/overlay \\
          -H "Content-Type: application/json" \\
          -d '{"name": "Aki", "message": "Hello world!"}'
        ```

        **Response**

        ```json
        { "status": "updated" }
        ```

        ---

        ## `POST /chat`

        Show an interactive chat card and wait for the user's response. The HTTP connection stays open until the user answers or dismisses.

        **Request Body**

        | Field              | Type       | Required | Description                                                     |
        | ------------------ | ---------- | -------- | --------------------------------------------------------------- |
        | `message`          | `string`   | **yes**  | The question or prompt to display.                              |
        | `name`             | `string`   | no       | Speaker name prefix.                                            |
        | `name_color`       | `string`   | no       | Hex color for the name prefix.                                  |
        | `image_base64`     | `string`   | no       | Base-64 encoded image.                                          |
        | `image_url`        | `string`   | no       | URL of an image to load.                                        |
        | `accent_hex`       | `string`   | no       | Accent color hex (default `"#7FD6FF"`).                         |
        | `proposed_answers` | `[string]` | no       | List of answer choices. If omitted, free-text input is shown.   |

        **Example — proposed answers**

        ```bash
        curl -X POST http://127.0.0.1:47037/chat \\
          -H "Content-Type: application/json" \\
          -d '{"name": "Aki", "message": "What would you like?", "proposed_answers": ["Explore", "Rest"]}'
        ```

        **Example — free-text input**

        ```bash
        curl -X POST http://127.0.0.1:47037/chat \\
          -H "Content-Type: application/json" \\
          -d '{"name": "Aki", "message": "How are you feeling today?"}'
        ```

        **Response** _(sent when the user answers)_

        ```json
        { "status": "answered", "answer": "Explore" }
        ```

        > If a new `/overlay`, `/chat`, `/collapse`, or `/clear` arrives while a `/chat` is pending, the pending chat is cancelled and returns `"answer": ""`.

        ---

        ## `GET /listen`

        Long-poll for the next user-initiated message from the Compose panel (⌘⇧K). The connection stays open until the user sends a message.

        Multiple `/listen` requests can be queued. When the user composes a message, all pending listeners receive it.

        **Example**

        ```bash
        curl http://127.0.0.1:47037/listen
        ```

        **Response**

        ```json
        { "status": "received", "message": "user's text" }
        ```

        ---

        ## `POST /collapse`

        Collapse (hide) the currently visible overlay card.

        **Response**

        ```json
        { "status": "collapsed" }
        ```

        ---

        ## `POST /clear`

        Dismiss all UI — overlay, chat, and compose.

        **Response**

        ```json
        { "status": "cleared" }
        ```

        ---

        ## Tips

        - Quick test: `curl -X POST http://127.0.0.1:47037/overlay -H 'Content-Type: application/json' -d '{"message": "Hello!"}'`
        - `/chat` and `/listen` are long-polling — set an appropriate timeout on your HTTP client.
        - The overlay never steals focus. Users interact by voluntarily clicking on the panel.
        """
        .split(separator: "\n")
        .map { line in
            // Remove leading 8-space indentation from the multiline string
            var s = String(line)
            var removed = 0
            while removed < 8 && s.hasPrefix(" ") {
                s.removeFirst()
                removed += 1
            }
            return s
        }
        .joined(separator: "\n")
}
