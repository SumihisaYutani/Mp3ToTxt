#pragma once

#include <QObject>
#include <QProcess>
#include <QString>

class TranscriptionManager : public QObject
{
    Q_OBJECT

    Q_PROPERTY(QString modelSize READ modelSize WRITE setModelSize NOTIFY modelSizeChanged)
    Q_PROPERTY(bool isProcessing READ isProcessing NOTIFY isProcessingChanged)
    Q_PROPERTY(QString result READ result NOTIFY resultChanged)
    Q_PROPERTY(QString statusMessage READ statusMessage NOTIFY statusMessageChanged)

public:
    explicit TranscriptionManager(QObject *parent = nullptr);

    QString modelSize() const;
    void setModelSize(const QString &size);
    bool isProcessing() const;
    QString result() const;
    QString statusMessage() const;

    Q_INVOKABLE void transcribe(const QString &fileUrl, const QString &language);
    Q_INVOKABLE void cancelTranscription();
    Q_INVOKABLE bool saveTxt();
    Q_INVOKABLE bool savePdf();
    Q_INVOKABLE QString getFileName(const QString &fileUrl) const;
    Q_INVOKABLE qint64 getFileSize(const QString &fileUrl) const;

signals:
    void modelSizeChanged();
    void isProcessingChanged();
    void resultChanged();
    void statusMessageChanged();
    void transcriptionError(const QString &message);
    void transcriptionFinished();

private slots:
    void onProcessReadyRead();
    void onProcessFinished(int exitCode, QProcess::ExitStatus status);

private:
    QString m_modelSize = "small";
    bool m_isProcessing = false;
    QString m_result;
    QString m_statusMessage;
    QProcess *m_process = nullptr;
    QString m_accumulatedText;
    QString m_lastError;
    QString m_rawOutput;
    QString m_sourceFilePath;

    void setIsProcessing(bool v);
    void setStatusMessage(const QString &msg);
    void setResult(const QString &r);
    QString toLocalPath(const QString &url) const;
    QString ensureScript() const;
    QString findPython() const;
};
