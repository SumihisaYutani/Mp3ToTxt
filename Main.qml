import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

ApplicationWindow {
    id: root
    // FHD (1920x1080) の画面で、横にエクスプローラーを並べてドラッグ&ドロップできるサイズ。
    // 表示スケール 125% などで画面が狭いときは、画面に収まるよう縮める
    width: Math.min(1100, Screen.width - 200)
    height: Math.min(800, Screen.height - 160)
    minimumWidth: 720
    minimumHeight: 580
    visible: true
    // 画面中央に置く（OS 任せだと下端がタスクバーに隠れることがある）
    Component.onCompleted: {
        x = Screen.virtualX + (Screen.width - width) / 2
        y = Screen.virtualY + Math.max(0, (Screen.height - height) / 2 - 10)
    }
    title: "Mp3ToTxt - 音声文字起こし"
    color: "#0d1117"

    property bool hasResult: transcriptionManager.result !== ""
    property bool editMode: false

    readonly property var queue: transcriptionManager.queue
    readonly property var selectedItem: (transcriptionManager.selectedIndex >= 0 && transcriptionManager.selectedIndex < queue.length)
                                        ? queue[transcriptionManager.selectedIndex] : null
    readonly property bool selectedDone: selectedItem !== null && selectedItem.status === "done"
    readonly property int doneCount: queue.filter(function(it) { return it.status === "done" }).length

    readonly property var statusLabels: ({
        pending: "待機", running: "処理中", done: "完了", empty: "文字なし", error: "エラー", cancelled: "中止"
    })
    readonly property var statusColors: ({
        pending: "#6e7681", running: "#58a6ff", done: "#3fb950", empty: "#8b949e", error: "#f85149", cancelled: "#d29922"
    })

    function enterEditMode() {
        resultArea.text = transcriptionManager.result   // バインディングを外して編集用に保持
        root.editMode = true
        transcriptionManager.editing = true
        resultArea.forceActiveFocus()
    }
    function finishEditMode(apply) {
        if (apply)
            transcriptionManager.applyEdit(resultArea.text)
        root.editMode = false
        transcriptionManager.editing = false
        resultArea.text = Qt.binding(function() { return transcriptionManager.result })
    }
    // 全置換。置換した件数を返す
    function replaceAll(findText, replaceText) {
        if (findText === "") return 0
        var parts = resultArea.text.split(findText)
        if (parts.length > 1)
            resultArea.text = parts.join(replaceText)
        return parts.length - 1
    }

    readonly property var langCodes: ["auto", "ja", "en", "zh", "ko", "fr", "de", "es"]

    // ---- Dialogs ----

    FileDialog {
        id: openDialog
        title: "音声ファイルを選択（複数選択可）"
        fileMode: FileDialog.OpenFiles
        nameFilters: [
            "音声ファイル (*.mp3 *.wav *.m4a *.ogg *.flac *.webm *.mp4)",
            "すべてのファイル (*)"
        ]
        onAccepted: transcriptionManager.setSources(selectedFiles)
    }

    FolderDialog {
        id: folderDialog
        title: "音声ファイルが入ったフォルダを選択"
        onAccepted: transcriptionManager.setSources([selectedFolder])
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
            id: mainScroll
            // 高さは外側のレイアウトで決める（中身の高さに連動させると Binding loop になる）
            implicitHeight: 100
            Layout.fillWidth: true; Layout.fillHeight: true
            contentWidth: availableWidth
            contentHeight: mainContent.height
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            // ウインドウが大きいときは表示範囲いっぱいまで伸ばし、余りを結果欄に回す
            Item {
                id: mainContent
                width: mainScroll.availableWidth
                height: Math.max(mainColumn.implicitHeight, mainScroll.height)

            ColumnLayout {
                id: mainColumn
                anchors.fill: parent
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
                                model: ["tiny  (高速・低精度)", "base", "small", "medium", "large-v3-turbo  (推奨)", "large-v3  (最高精度・低速)"]
                                readonly property var values: ["tiny", "base", "small", "medium", "large-v3-turbo", "large-v3"]
                                // 保存済みの設定を復元（見つからなければ small）
                                currentIndex: values.indexOf(transcriptionManager.modelSize) >= 0 ? values.indexOf(transcriptionManager.modelSize) : 2
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
                    id: dropZone
                    Layout.fillWidth: true
                    Layout.leftMargin: 20; Layout.rightMargin: 20
                    height: 108
                    radius: 8
                    readonly property bool hasFiles: root.queue.length > 0
                    // 処理中・修正中はファイルを差し替えない
                    readonly property bool accepting: !transcriptionManager.isProcessing && !root.editMode
                    color: dropArea.containsDrag ? "#1c2d3f" : (hasFiles ? "#0d1f10" : "#161b22")
                    border.color: dropArea.containsDrag ? "#58a6ff" : (hasFiles ? "#3fb950" : "#30363d")
                    border.width: dropArea.containsDrag ? 2 : 1
                    opacity: accepting ? 1.0 : 0.6
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Behavior on border.color { ColorAnimation { duration: 120 } }

                    DropArea {
                        id: dropArea
                        anchors.fill: parent
                        enabled: dropZone.accepting
                        onDropped: (drop) => { if (drop.hasUrls) transcriptionManager.setSources(drop.urls) }
                    }
                    MouseArea {
                        anchors.fill: parent
                        enabled: dropZone.accepting
                        cursorShape: Qt.PointingHandCursor
                        onClicked: openDialog.open()
                    }
                    ColumnLayout {
                        anchors.centerIn: parent; spacing: 4
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: dropZone.hasFiles ? "\u2713" : "+"
                            font.pixelSize: 24
                            color: dropZone.hasFiles ? "#3fb950" : "#484f58"
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: root.queue.length === 0 ? "ここにファイル・フォルダをドロップ、またはクリックして選択"
                                : root.queue.length === 1 ? root.queue[0].name
                                : root.queue.length + " 件のファイル"
                            color: dropZone.hasFiles ? "#3fb950" : "#c9d1d9"
                            font.pixelSize: 13; font.bold: dropZone.hasFiles
                            elide: Text.ElideMiddle
                            Layout.maximumWidth: dropZone.width - 40
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            visible: root.queue.length === 1
                            text: { if (root.queue.length !== 1) return ""; var s = transcriptionManager.getFileSize(root.queue[0].path); return s < 1048576 ? (s/1024).toFixed(1)+" KB" : (s/1048576).toFixed(1)+" MB" }
                            color: "#6e7681"; font.pixelSize: 11
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            visible: root.queue.length !== 1
                            text: root.queue.length > 1 ? "下の一覧の順（名前順）に処理します" : "MP3 / WAV / M4A / OGG / FLAC / WEBM / MP4"
                            color: "#484f58"; font.pixelSize: 11
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20; Layout.rightMargin: 20
                    Layout.topMargin: -6
                    spacing: 8
                    Item { Layout.fillWidth: true }
                    Button {
                        text: "ファイルを選択"; implicitWidth: 110; implicitHeight: 28
                        enabled: dropZone.accepting
                        background: Rectangle { color: parent.pressed ? "#21262d" : "#161b22"; radius: 6; border.color: "#30363d"; border.width: 1 }
                        contentItem: Text { text: parent.text; color: parent.enabled ? "#c9d1d9" : "#484f58"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        onClicked: openDialog.open()
                    }
                    Button {
                        text: "フォルダを選択"; implicitWidth: 110; implicitHeight: 28
                        enabled: dropZone.accepting
                        background: Rectangle { color: parent.pressed ? "#21262d" : "#161b22"; radius: 6; border.color: "#30363d"; border.width: 1 }
                        contentItem: Text { text: parent.text; color: parent.enabled ? "#c9d1d9" : "#484f58"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        onClicked: folderDialog.open()
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
                            // 修正中に開始すると、全件やり直しで修正内容が消えることがあるため無効化
                            enabled: !transcriptionManager.isProcessing && !root.editMode && root.queue.length > 0
                            background: Rectangle {
                                color: parent.enabled ? (parent.pressed ? "#1a7f37" : "#238636") : "#21262d"
                                radius: 8
                                Behavior on color { ColorAnimation { duration: 120 } }
                            }
                            contentItem: Text {
                                text: transcriptionManager.isProcessing ? "処理中..."
                                    : root.queue.length > 1 ? root.queue.length + " 件を順番に文字起こし"
                                    : "文字起こし開始"
                                color: transcriptionManager.isProcessing ? "#6e7681" : "#ffffff"
                                font.pixelSize: 14; font.bold: true
                                horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                            }
                            onClicked: transcriptionManager.start(root.langCodes[languageCombo.currentIndex])
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

                // --- Queue list (複数ファイル時) ---
                Rectangle {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20; Layout.rightMargin: 20
                    visible: root.queue.length > 1
                    implicitHeight: queueCol.implicitHeight + 20
                    color: "#161b22"; radius: 8
                    border.color: "#21262d"; border.width: 1

                    ColumnLayout {
                        id: queueCol
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
                        spacing: 6

                        RowLayout {
                            Layout.fillWidth: true; spacing: 8
                            Text { text: "ファイル一覧"; color: "#6e7681"; font.pixelSize: 11; font.bold: true }
                            Text { text: "完了 " + root.doneCount + " / " + root.queue.length; color: "#484f58"; font.pixelSize: 11 }
                            Item { Layout.fillWidth: true }
                            Button {
                                text: "すべて TXT 保存"; implicitWidth: 110; implicitHeight: 26
                                visible: root.doneCount > 0 && !root.editMode
                                background: Rectangle { color: parent.pressed ? "#1f6feb" : "#161b22"; radius: 5; border.color: "#58a6ff"; border.width: 1 }
                                contentItem: Text { text: parent.text; color: "#58a6ff"; font.pixelSize: 11; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                onClicked: transcriptionManager.saveAllTxt()
                            }
                            Button {
                                text: "すべて PDF 保存"; implicitWidth: 110; implicitHeight: 26
                                visible: root.doneCount > 0 && !root.editMode
                                background: Rectangle { color: parent.pressed ? "#6e1c1c" : "#161b22"; radius: 5; border.color: "#f85149"; border.width: 1 }
                                contentItem: Text { text: parent.text; color: "#f85149"; font.pixelSize: 11; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                onClicked: transcriptionManager.saveAllPdf()
                            }
                        }

                        ListView {
                            id: queueView
                            Layout.fillWidth: true
                            implicitHeight: Math.min(contentHeight, 30 * 7)
                            clip: true
                            model: root.queue
                            ScrollBar.vertical: ScrollBar { policy: queueView.contentHeight > queueView.height ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded }

                            delegate: Rectangle {
                                required property var modelData
                                required property int index
                                readonly property bool selected: index === transcriptionManager.selectedIndex
                                width: queueView.width - 12
                                height: 30; radius: 4
                                color: selected ? "#1c2d3f" : (rowMouse.containsMouse && !root.editMode ? "#1c2128" : "transparent")
                                border.color: selected ? "#58a6ff" : "transparent"; border.width: 1

                                MouseArea {
                                    id: rowMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    // 修正中は他のファイルへ切り替えない（未確定の修正を守る）
                                    enabled: !root.editMode
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: transcriptionManager.selectedIndex = index
                                }
                                RowLayout {
                                    anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
                                    spacing: 8
                                    Text { text: (index + 1) + "."; color: "#484f58"; font.pixelSize: 11; Layout.preferredWidth: 26 }
                                    Text {
                                        text: modelData.name; color: "#c9d1d9"; font.pixelSize: 12
                                        elide: Text.ElideMiddle; Layout.fillWidth: true
                                    }
                                    Text { text: "(修正済み)"; color: "#d29922"; font.pixelSize: 11; visible: modelData.edited }
                                    BusyIndicator {
                                        visible: modelData.status === "running"; running: visible
                                        implicitWidth: 14; implicitHeight: 14
                                    }
                                    Text {
                                        text: root.statusLabels[modelData.status]
                                        color: root.statusColors[modelData.status]
                                        font.pixelSize: 11; font.bold: modelData.status === "running"
                                        horizontalAlignment: Text.AlignRight
                                        Layout.preferredWidth: 52
                                    }
                                }
                            }
                        }
                    }
                }

                // --- Result area ---
                Rectangle {
                    id: resultBox
                    Layout.fillWidth: true
                    Layout.leftMargin: 20; Layout.rightMargin: 20
                    implicitHeight: root.editMode ? 460 : 230
                    Layout.minimumHeight: implicitHeight
                    Layout.fillHeight: true
                    visible: root.hasResult || (root.selectedItem !== null && root.selectedItem.status !== "pending")
                    color: "#161b22"; radius: 8
                    border.color: root.editMode ? "#d29922" : "#21262d"
                    border.width: root.editMode ? 2 : 1

                    ColumnLayout {
                        anchors { fill: parent; margins: 12 }
                        spacing: 8
                        RowLayout {
                            Layout.fillWidth: true
                            Text {
                                text: (root.editMode ? "修正モード — 直接編集できます" : "文字起こし結果")
                                      + (root.queue.length > 1 && root.selectedItem ? "  —  " + root.selectedItem.name : "")
                                elide: Text.ElideMiddle
                                Layout.fillWidth: true
                                color: root.editMode ? "#d29922" : "#6e7681"
                                font.pixelSize: 11; font.bold: true
                            }
                            Text {
                                text: "(修正済み)"; color: "#d29922"; font.pixelSize: 11
                                visible: !root.editMode && transcriptionManager.isEdited
                            }
                            Text { text: resultArea.length + " 文字"; color: "#484f58"; font.pixelSize: 11; visible: root.hasResult }
                        }

                        // 選択中のファイルのエラー
                        Text {
                            Layout.fillWidth: true
                            visible: root.selectedItem !== null && root.selectedItem.status === "error"
                            text: root.selectedItem ? root.selectedItem.error : ""
                            color: "#f85149"; font.pixelSize: 12; wrapMode: Text.Wrap
                        }

                        // 修正モード: 一括置換
                        RowLayout {
                            Layout.fillWidth: true; spacing: 6
                            visible: root.editMode
                            TextField {
                                id: findField
                                Layout.fillWidth: true; implicitHeight: 28
                                placeholderText: "検索する語"
                                color: "#c9d1d9"; placeholderTextColor: "#484f58"; font.pixelSize: 12
                                selectByMouse: true
                                background: Rectangle { color: "#0d1117"; radius: 4; border.color: findField.activeFocus ? "#58a6ff" : "#30363d"; border.width: 1 }
                                onTextChanged: replaceInfo.text = ""
                            }
                            Text { text: "\u2192"; color: "#6e7681"; font.pixelSize: 12 }
                            TextField {
                                id: replaceField
                                Layout.fillWidth: true; implicitHeight: 28
                                placeholderText: "置換後の語"
                                color: "#c9d1d9"; placeholderTextColor: "#484f58"; font.pixelSize: 12
                                selectByMouse: true
                                background: Rectangle { color: "#0d1117"; radius: 4; border.color: replaceField.activeFocus ? "#58a6ff" : "#30363d"; border.width: 1 }
                                onAccepted: replaceAllButton.clicked()
                            }
                            Button {
                                id: replaceAllButton
                                text: "すべて置換"; implicitWidth: 90; implicitHeight: 28
                                enabled: findField.text !== ""
                                background: Rectangle { color: parent.pressed ? "#21262d" : "#161b22"; radius: 4; border.color: parent.enabled ? "#58a6ff" : "#30363d"; border.width: 1 }
                                contentItem: Text { text: parent.text; color: parent.enabled ? "#58a6ff" : "#484f58"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                onClicked: {
                                    var n = root.replaceAll(findField.text, replaceField.text)
                                    replaceInfo.text = n > 0 ? n + " 件置換" : "見つかりません"
                                }
                            }
                            Text { id: replaceInfo; color: "#8b949e"; font.pixelSize: 11; Layout.minimumWidth: 70 }
                        }
                        ScrollView {
                            Layout.fillWidth: true; Layout.fillHeight: true
                            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                            TextArea {
                                id: resultArea
                                text: transcriptionManager.result
                                color: "#c9d1d9"; font.pixelSize: 13
                                wrapMode: TextEdit.Wrap; readOnly: !root.editMode
                                selectByMouse: true
                                placeholderText: "文字起こし結果がここに表示されます..."
                                background: Rectangle { color: root.editMode ? "#0d1117" : "transparent"; radius: 4 }
                                padding: root.editMode ? 8 : 0
                            }
                        }
                    }
                }

                // --- Save / Copy buttons ---
                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20; Layout.rightMargin: 20
                    spacing: 8
                    visible: root.selectedDone

                    // --- 修正モード中のボタン ---
                    Button {
                        text: "修正を確定"; implicitWidth: 120; implicitHeight: 32
                        visible: root.editMode
                        background: Rectangle { color: parent.pressed ? "#1a7f37" : "#238636"; radius: 6 }
                        contentItem: Text { text: parent.text; color: "#ffffff"; font.pixelSize: 12; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        onClicked: root.finishEditMode(true)
                    }
                    Button {
                        text: "破棄"; implicitWidth: 90; implicitHeight: 32
                        visible: root.editMode
                        background: Rectangle { color: parent.pressed ? "#21262d" : "#161b22"; radius: 6; border.color: "#30363d"; border.width: 1 }
                        contentItem: Text { text: parent.text; color: "#8b949e"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        onClicked: root.finishEditMode(false)
                    }

                    // --- 通常時のボタン ---
                    Button {
                        text: "修正モード"; implicitWidth: 110; implicitHeight: 32
                        visible: !root.editMode
                        background: Rectangle { color: parent.pressed ? "#3d2e00" : "#161b22"; radius: 6; border.color: "#d29922"; border.width: 1 }
                        contentItem: Text { text: parent.text; color: "#d29922"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        onClicked: root.enterEditMode()
                    }
                    Button {
                        text: "TXT で保存"; implicitWidth: 120; implicitHeight: 32
                        background: Rectangle { color: parent.pressed ? "#1f6feb" : "#161b22"; radius: 6; border.color: "#58a6ff"; border.width: 1 }
                        contentItem: Text { text: parent.text; color: "#58a6ff"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        visible: !root.editMode
                        onClicked: transcriptionManager.saveTxt()
                    }
                    Button {
                        text: "PDF で保存"; implicitWidth: 120; implicitHeight: 32
                        background: Rectangle { color: parent.pressed ? "#6e1c1c" : "#161b22"; radius: 6; border.color: "#f85149"; border.width: 1 }
                        contentItem: Text { text: parent.text; color: "#f85149"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        visible: !root.editMode
                        onClicked: transcriptionManager.savePdf()
                    }
                    Button {
                        text: "コピー"; implicitWidth: 90; implicitHeight: 32
                        background: Rectangle { color: parent.pressed ? "#21262d" : "#161b22"; radius: 6; border.color: "#30363d"; border.width: 1 }
                        contentItem: Text { text: parent.text; color: "#8b949e"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        visible: !root.editMode
                        onClicked: { resultArea.selectAll(); resultArea.copy(); resultArea.deselect() }
                    }
                    Item { Layout.fillWidth: true }
                    Button {
                        text: "元に戻す"; implicitWidth: 90; implicitHeight: 32
                        visible: !root.editMode && transcriptionManager.isEdited
                        background: Rectangle { color: parent.pressed ? "#21262d" : "#161b22"; radius: 6; border.color: "#30363d"; border.width: 1 }
                        contentItem: Text { text: parent.text; color: "#8b949e"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        onClicked: transcriptionManager.revertEdits()
                    }
                }

                // 結果欄がないときは、余った高さをここで受けて上に詰める
                Item { implicitHeight: 16; Layout.fillHeight: !resultBox.visible }
            }
            }
        }
    }
}
