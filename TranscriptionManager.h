#pragma once

#include <QList>
#include <QObject>
#include <QProcess>
#include <QString>
#include <QStringList>
#include <QUrl>
#include <QVariantList>

class TranscriptionManager : public QObject
{
    Q_OBJECT

    Q_PROPERTY(QString modelSize READ modelSize WRITE setModelSize NOTIFY modelSizeChanged)
    Q_PROPERTY(bool isProcessing READ isProcessing NOTIFY isProcessingChanged)
    // 選択中のファイルの文字起こし結果
    Q_PROPERTY(QString result READ result NOTIFY resultChanged)
    Q_PROPERTY(QString statusMessage READ statusMessage NOTIFY statusMessageChanged)
    Q_PROPERTY(bool isEdited READ isEdited NOTIFY resultChanged)
    // キュー: [{ name, path, status, error, edited }]  status は "pending" / "running" / "done" / "empty" / "error" / "cancelled"
    Q_PROPERTY(QVariantList queue READ queue NOTIFY queueChanged)
    Q_PROPERTY(int selectedIndex READ selectedIndex WRITE selectIndex NOTIFY selectedIndexChanged)
    // 修正モード中は true。処理中のファイルへ選択が自動で移らないようにする
    Q_PROPERTY(bool editing READ editing WRITE setEditing NOTIFY editingChanged)

public:
    explicit TranscriptionManager(QObject *parent = nullptr);

    QString modelSize() const;
    void setModelSize(const QString &size);
    bool isProcessing() const;
    QString result() const;
    QString statusMessage() const;
    bool isEdited() const;
    QVariantList queue() const;
    int selectedIndex() const;
    void selectIndex(int index);
    bool editing() const;
    void setEditing(bool v);

    // ファイル / フォルダの URL を受け取り、音声ファイルをキューに並べる（フォルダは名前順に展開）
    Q_INVOKABLE int setSources(const QList<QUrl> &urls);
    Q_INVOKABLE void start(const QString &language);
    Q_INVOKABLE void cancelTranscription();
    Q_INVOKABLE void applyEdit(const QString &text);
    Q_INVOKABLE void revertEdits();
    Q_INVOKABLE bool saveTxt();
    Q_INVOKABLE bool savePdf();
    Q_INVOKABLE int saveAllTxt();
    Q_INVOKABLE int saveAllPdf();
    Q_INVOKABLE QString getFileName(const QString &fileUrl) const;
    Q_INVOKABLE qint64 getFileSize(const QString &fileUrl) const;

signals:
    void modelSizeChanged();
    void isProcessingChanged();
    void resultChanged();
    void statusMessageChanged();
    void queueChanged();
    void selectedIndexChanged();
    void editingChanged();
    void transcriptionError(const QString &message);
    void transcriptionFinished();

private slots:
    void onProcessReadyRead();
    void onProcessFinished(int exitCode, QProcess::ExitStatus status);

private:
    enum class Status { Pending, Running, Done, Empty, Error, Cancelled };

    struct Item {
        QString path;
        Status status = Status::Pending;
        QString result;
        QString original;   // 修正前の文字起こし結果（元に戻す用）
        QString error;
    };

    QString m_modelSize = "small";
    bool m_isProcessing = false;
    QString m_statusMessage;
    QProcess *m_process = nullptr;
    QString m_lastError;
    QString m_rawOutput;

    QList<Item> m_items;
    QList<int> m_batch;        // 今回 Python に渡したファイル（m_items のインデックス）
    int m_running = -1;        // 処理中の m_items インデックス
    int m_selected = -1;
    bool m_editing = false;

    void setIsProcessing(bool v);
    void setStatusMessage(const QString &msg);
    void setItemStatus(int index, Status status);
    void appendSegment(int index, const QString &seg);
    void finishItem(int index);
    bool writeTxt(int index);
    bool writePdf(int index);
    QString progressText() const;
    QString toLocalPath(const QString &url) const;
    QString ensureScript() const;
    QString findPython() const;
};
