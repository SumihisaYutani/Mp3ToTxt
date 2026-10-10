import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

ApplicationWindow {
    id: root
    width: 900
    height: 740
    minimumWidth: 720
    minimumHeight: 580
    visible: true
    title: "Mp3ToTxt - 音声文字起こし"
    color: "#0d1117"

    property string selectedFileUrl: ""
    property bool hasResult: transcriptionManager.result !== ""

    readonly property var langCodes: ["auto", "ja", "en", "zh", "ko", "fr", "de", "es"]

    // ---- Dialogs ----

    FileDialog {
        id: openDialog
        title: "音声ファイルを選択"
        nameFilters: [
            "音声ファイル (*.mp3 *.wav *.m4a *.ogg *.flac *.webm *.mp4)",
            "すべてのファイル (*)"
        ]
        onAccepted: root.selectedFileUrl = selectedFile.toString()
    }


    // Error popup
    Popup {
        id: errorPopup
        property string message: ""
        anchors.centerIn: Overlay.overlay
        width: Math.min(root.width - 60, 520)
        padding: 20
        modal: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        background: Rectangle {
            color: "#1c1c2e"; radius: 10
            border.color: "#f85149"; border.width: 1
        }
        ColumnLayout {
            width: parent.width - 40
            spacing: 14
            Text { text: "エラー"; color: "#f85149"; font.pixelSize: 14; font.bold: true }
            ScrollView {
                Layout.fillWidth: true
                implicitHeight: Math.min(errorText.implicitHeight + 4, 300)
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                TextArea {
                    id: errorText
                    text: errorPopup.message
                    color: "#c9d1d9"; font.pixelSize: 12; font.family: "Consolas, Courier New"
                    wrapMode: Text.Wrap; readOnly: true
                    background: Rectangle { color: "#0d1117"; radius: 4 }
                    padding: 8
                }
            }
            Button {
                text: "閉じる"; Layout.alignment: Qt.AlignRight
                implicitWidth: 80; implicitHeight: 30
                onClicked: errorPopup.close()
                background: Rectangle { color: parent.pressed ? "#6e1c1c" : "#2d1c1c"; radius: 6; border.color: "#f85149"; border.width: 1 }
                contentItem: Text { text: parent.text; color: "#f85149"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
            }
        }
    }

    Connections {
        target: transcriptionManager
        function onTranscriptionError(message) {
            errorPopup.message = message
            errorPopup.open()
        }
    }

    // ---- Main layout ----

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Header
        Rectangle {
            Layout.fillWidth: true; height: 52
            color: "#161b22"
            RowLayout {
                anchors { fill: parent; leftMargin: 20; rightMargin: 20 }
                spacing: 10
                Text { text: "Mp3ToTxt"; font.pixelSize: 19; font.bold: true; color: "#58a6ff" }
                Text { text: "音声文字起こし"; font.pixelSize: 12; color: "#6e7681" }
                Item { Layout.fillWidth: true }
                Text { text: "faster-whisper (ローカル処理)"; font.pixelSize: 10; color: "#484f58" }
            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: "#21262d" }

        ScrollView {
            Layout.fillWidth: true; Layout.fillHeight: true
            contentWidth: availableWidth
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            ColumnLayout {
                width: parent.width
                spacing: 14

                Item { height: 4 }

                // --- Setup info banner (always visible) ---
                Rectangle {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20; Layout.rightMargin: 20
                    implicitHeight: infoCol.implicitHeight + 16
                    color: "#0d1f2d"; radius: 8
                    border.color: "#1f3a5c"; border.width: 1

                    ColumnLayout {
                        id: infoCol
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
                        spacing: 4
                        Text {
                            text: "初回セットアップ (1回だけ実行)"
                            color: "#58a6ff"; font.pixelSize: 12; font.bold: true
                        }
                        Text {
                            text: "コマンドプロンプトで:  pip install faster-whisper"
                            color: "#8b949e"; font.pixelSize: 12
                            font.family: "Consolas, Courier New, monospace"
                        }
                        Text {
                            text: "Python 未インストールの場合は https://www.python.org からダウンロード"
                            color: "#6e7681"; font.pixelSize: 11
                        }
                    }
                }

                // --- Settings card ---
                Rectangle {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20; Layout.rightMargin: 20
                    implicitHeight: settingsCol.implicitHeight + 24
                    color: "#161b22"; radius: 8
                    border.color: "#21262d"; border.width: 1

                    ColumnLayout {
                        id: settingsCol
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
                        spacing: 10

                        // Language row
                        RowLayout {
                            Layout.fillWidth: true; spacing: 8
                            Text { text: "言語"; color: "#8b949e"; font.pixelSize: 12; Layout.preferredWidth: 100 }
                            ComboBox {
                                id: languageCombo
                                model: ["自動検出", "日本語", "英語", "中国語", "韓国語", "フランス語", "ドイツ語", "スペイン語"]
                                currentIndex: 1
                                implicitWidth: 150; implicitHeight: 30
                                background: Rectangle { color: "#0d1117"; radius: 6; border.color: parent.down ? "#58a6ff" : "#30363d"; border.width: 1 }
                                contentItem: Text { leftPadding: 10; text: languageCombo.displayText; color: "#c9d1d9"; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter }
                                delegate: ItemDelegate {
                                    width: languageCombo.width
                                    contentItem: Text { text: modelData; color: highlighted ? "#58a6ff" : "#c9d1d9"; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter; leftPadding: 10 }
                                    highlighted: languageCombo.highlightedIndex === index
                                    background: Rectangle { color: highlighted ? "#1c2d3f" : "transparent" }
                                }
                                popup: Popup {
                                    y: languageCombo.height; width: languageCombo.width
                                    implicitHeight: contentItem.implicitHeight; padding: 1
                                    background: Rectangle { color: "#161b22"; border.color: "#30363d"; radius: 6 }
                                    contentItem: ListView { implicitHeight: contentHeight; model: languageCombo.delegateModel; clip: true }
                                }
                            }
                            Item { width: 24 }
                            // Model size row
                            Text { text: "モデル"; color: "#8b949e"; font.pixelSize: 12 }
                            ComboBox {
                                id: modelCombo
                                model: ["tiny  (高速・低精度)", "base", "small  (推奨)", "medium  (高精度)", "large-v3  (最高精度)"]
                                readonly property var values: ["tiny", "base", "small", "medium", "large-v3"]
                                currentIndex: 2   // small default
                                implicitWidth: 190; implicitHeight: 30
                                onCurrentIndexChanged: transcriptionManager.modelSize = values[currentIndex]
                                background: Rectangle { color: "#0d1117"; radius: 6; border.color: parent.down ? "#58a6ff" : "#30363d"; border.width: 1 }
                                contentItem: Text { leftPadding: 10; text: modelCombo.displayText; color: "#c9d1d9"; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter }
                                delegate: ItemDelegate {
                                    width: modelCombo.width
                                    contentItem: Text { text: modelData; color: highlighted ? "#58a6ff" : "#c9d1d9"; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter; leftPadding: 10 }
                                    highlighted: modelCombo.highlightedIndex === index
                                    background: Rectangle { color: highlighted ? "#1c2d3f" : "transparent" }
                                }
                                popup: Popup {
                                    y: modelCombo.height; width: modelCombo.width
                                    implicitHeight: contentItem.implicitHeight; padding: 1
                                    background: Rectangle { color: "#161b22"; border.color: "#30363d"; radius: 6 }
                                    contentItem: ListView { implicitHeight: contentHeight; model: modelCombo.delegateModel; clip: true }
                                }
                            }
                            Item { Layout.fillWidth: true }
                        }
                    }
                }

                // --- File drop zone ---
                Rectangle {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20; Layout.rightMargin: 20
                    height: 108
                    radius: 8
                    color: dropArea.containsDrag ? "#1c2d3f" : (root.selectedFileUrl !== "" ? "#0d1f10" : "#161b22")
                    border.color: dropArea.containsDrag ? "#58a6ff" : (root.selectedFileUrl !== "" ? "#3fb950" : "#30363d")
                    border.width: dropArea.containsDrag ? 2 : 1
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Behavior on border.color { ColorAnimation { duration: 120 } }

                    DropArea {
                        id: dropArea
                        anchors.fill: parent
                        onDropped: { if (drop.hasUrls && drop.urls.length > 0) root.selectedFileUrl = drop.urls[0].toString() }
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: openDialog.open()
                    }
                    ColumnLayout {
                        anchors.centerIn: parent; spacing: 4
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: root.selectedFileUrl !== "" ? "\u2713" : "+"
                            font.pixelSize: 24
                            color: root.selectedFileUrl !== "" ? "#3fb950" : "#484f58"
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: root.selectedFileUrl !== "" ? transcriptionManager.getFileName(root.selectedFileUrl) : "ここにファイルをドロップ、またはクリックして選択"
                            color: root.selectedFileUrl !== "" ? "#3fb950" : "#c9d1d9"
                            font.pixelSize: 13; font.bold: root.selectedFileUrl !== ""
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            visible: root.selectedFileUrl !== ""
                            text: { var s = transcriptionManager.getFileSize(root.selectedFileUrl); return s < 1048576 ? (s/1024).toFixed(1)+" KB" : (s/1048576).toFixed(1)+" MB" }
                            color: "#6e7681"; font.pixelSize: 11
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            visible: root.selectedFileUrl === ""
                            text: "MP3 / WAV / M4A / OGG / FLAC / WEBM"
                            color: "#484f58"; font.pixelSize: 11
                        }
                    }
                }

                // --- Buttons + progress ---
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20; Layout.rightMargin: 20
                    spacing: 8

                    RowLayout {
                        Layout.fillWidth: true; spacing: 8

                        Button {
                            Layout.fillWidth: true; implicitHeight: 40
                            enabled: !transcriptionManager.isProcessing && root.selectedFileUrl !== ""
                            background: Rectangle {
                                color: parent.enabled ? (parent.pressed ? "#1a7f37" : "#238636") : "#21262d"
                                radius: 8
                                Behavior on color { ColorAnimation { duration: 120 } }
                            }
                            contentItem: Text {
                                text: transcriptionManager.isProcessing ? "処理中..." : "文字起こし開始"
                                color: transcriptionManager.isProcessing ? "#6e7681" : "#ffffff"
                                font.pixelSize: 14; font.bold: true
                                horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                            }
                            onClicked: transcriptionManager.transcribe(root.selectedFileUrl, root.langCodes[languageCombo.currentIndex])
                        }

                        Button {
                            text: "キャンセル"
                            visible: transcriptionManager.isProcessing
                            implicitWidth: 100; implicitHeight: 40
                            background: Rectangle { color: parent.pressed ? "#6e1c1c" : "#21262d"; radius: 8; border.color: "#f85149"; border.width: 1 }
                            contentItem: Text { text: parent.text; color: "#f85149"; font.pixelSize: 13; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                            onClicked: transcriptionManager.cancelTranscription()
                        }
                    }

                    // Busy indicator / status
                    Rectangle {
                        Layout.fillWidth: true
                        visible: transcriptionManager.isProcessing
                                 && transcriptionManager.statusMessage.includes("ダウンロード")
                        height: downloadNote.implicitHeight + 16
                        color: "#1a2a1a"; radius: 6
                        border.color: "#3fb950"; border.width: 1

                        Text {
                            id: downloadNote
                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 10 }
                            text: "初回のみ Whisper モデルをダウンロードしています。\nネット接続を確認しながらしばらくお待ちください (small モデル = 約 244 MB)。"
                            color: "#3fb950"; font.pixelSize: 12; wrapMode: Text.Wrap
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        visible: transcriptionManager.statusMessage !== ""

                        BusyIndicator {
                            visible: transcriptionManager.isProcessing
                            running: transcriptionManager.isProcessing
                            implicitWidth: 18; implicitHeight: 18
                        }
                        Text {
                            text: transcriptionManager.statusMessage
                            color: transcriptionManager.statusMessage.startsWith("完了") ? "#3fb950" : "#8b949e"
                            font.pixelSize: 12; wrapMode: Text.Wrap
                            Layout.fillWidth: true
                        }
                    }
                }

                // --- Result area ---
                Rectangle {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20; Layout.rightMargin: 20
                    implicitHeight: 230
                    visible: root.hasResult || transcriptionManager.isProcessing
                    color: "#161b22"; radius: 8
                    border.color: "#21262d"; border.width: 1

                    ColumnLayout {
                        anchors { fill: parent; margins: 12 }
                        spacing: 8
                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: "文字起こし結果"; color: "#6e7681"; font.pixelSize: 11; font.bold: true }
                            Item { Layout.fillWidth: true }
                            Text { text: transcriptionManager.result.length + " 文字"; color: "#484f58"; font.pixelSize: 11; visible: root.hasResult }
                        }
                        ScrollView {
                            Layout.fillWidth: true; Layout.fillHeight: true
                            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                            TextArea {
                                id: resultArea
                                text: transcriptionManager.result
                                color: "#c9d1d9"; font.pixelSize: 13
                                wrapMode: TextEdit.Wrap; readOnly: true
                                placeholderText: "文字起こし結果がここに表示されます..."
                                background: Rectangle { color: "transparent" }
                                padding: 0
                            }
                        }
                    }
                }

                // --- Save / Copy buttons ---
                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20; Layout.rightMargin: 20
                    spacing: 8
                    visible: root.hasResult

                    Button {
                        text: "TXT で保存"; implicitWidth: 120; implicitHeight: 32
                        background: Rectangle { color: parent.pressed ? "#1f6feb" : "#161b22"; radius: 6; border.color: "#58a6ff"; border.width: 1 }
                        contentItem: Text { text: parent.text; color: "#58a6ff"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        onClicked: transcriptionManager.saveTxt()
                    }
                    Button {
                        text: "PDF で保存"; implicitWidth: 120; implicitHeight: 32
                        background: Rectangle { color: parent.pressed ? "#6e1c1c" : "#161b22"; radius: 6; border.color: "#f85149"; border.width: 1 }
                        contentItem: Text { text: parent.text; color: "#f85149"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        onClicked: transcriptionManager.savePdf()
                    }
                    Button {
                        text: "コピー"; implicitWidth: 90; implicitHeight: 32
                        background: Rectangle { color: parent.pressed ? "#21262d" : "#161b22"; radius: 6; border.color: "#30363d"; border.width: 1 }
                        contentItem: Text { text: parent.text; color: "#8b949e"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        onClicked: { resultArea.selectAll(); resultArea.copy(); resultArea.deselect() }
                    }
                    Item { Layout.fillWidth: true }
                }

                Item { height: 16 }
            }
        }
    }
}
