#include "TranscriptionManager.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMarginsF>
#include <QPageLayout>
#include <QPageSize>
#include <QPdfWriter>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QSettings>
#include <QStandardPaths>
#include <QTextDocument>
#include <QTextStream>
#include <QUrl>

// Python script embedded as a string literal — written to a temp file at runtime
static const char *TRANSCRIBE_SCRIPT = R"PYTHON(
import sys, os, threading, time

def main():
    if len(sys.argv) < 4:
        print("FATAL:引数が不足しています", flush=True)
        sys.exit(1)

    audio_file = sys.argv[1]
    language   = sys.argv[2]
    model_size = sys.argv[3]

    try:
        from faster_whisper import WhisperModel
    except ImportError:
        print("FATAL:faster-whisper がインストールされていません。\nコマンドプロンプトで: pip install faster-whisper", flush=True)
        sys.exit(2)

    # av 19+ で metadata_errors 引数が削除されたため互換パッチを当てる
    try:
        import av as _av
        _orig_open = _av.open
        def _patched_open(*args, **kwargs):
            kwargs.pop('metadata_errors', None)
            return _orig_open(*args, **kwargs)
        _av.open = _patched_open
    except Exception:
        pass

    lang = None if language == "auto" else language

    # tqdm のプログレスバーが出力を汚さないよう無効化
    os.environ["TQDM_DISABLE"] = "1"

    # キャッシュ確認
    cache_dir = os.path.join(os.path.expanduser("~"), ".cache", "huggingface", "hub",
                             f"models--Systran--faster-whisper-{model_size}")
    is_cached = os.path.isdir(cache_dir)

    if is_cached:
        print(f"STATUS:モデルを読み込み中 ({model_size})...", flush=True)
    else:
        print(f"STATUS:モデルをダウンロード中 ({model_size}) — 初回のみ数分かかります...", flush=True)

    # ハートビート: モデル読み込み中もUIが生きていることを示す
    done_event = threading.Event()
    def heartbeat():
        elapsed = 0
        while not done_event.is_set():
            time.sleep(4)
            elapsed += 4
            if not done_event.is_set():
                if is_cached:
                    print(f"STATUS:モデルを読み込み中... ({elapsed}秒)", flush=True)
                else:
                    print(f"STATUS:ダウンロード中... ({elapsed}秒経過、完了までネット速度による)", flush=True)

    t = threading.Thread(target=heartbeat, daemon=True)
    t.start()

    try:
        model = WhisperModel(model_size, device="cpu", compute_type="int8")
    except Exception as e:
        done_event.set()
        print(f"FATAL:モデルの読み込みに失敗しました:\n{e}", flush=True)
        sys.exit(3)
    finally:
        done_event.set()

    print("STATUS:音声を解析中...", flush=True)

    try:
        segments, info = model.transcribe(audio_file, language=lang, beam_size=5)
        for segment in segments:
            text = segment.text.strip()
            if text:
                print(f"SEGMENT:{text}", flush=True)
    except Exception as e:
        print(f"FATAL:文字起こしに失敗しました:\n{e}", flush=True)
        sys.exit(4)

    print("DONE", flush=True)

if __name__ == "__main__":
    main()
)PYTHON";

// -----------------------------------------------------------------------

TranscriptionManager::TranscriptionManager(QObject *parent)
    : QObject(parent)
{
    QSettings settings;
    m_modelSize = settings.value("modelSize", "small").toString();
}

QString TranscriptionManager::modelSize() const { return m_modelSize; }

void TranscriptionManager::setModelSize(const QString &size)
{
    if (m_modelSize == size) return;
    m_modelSize = size;
    QSettings settings;
    settings.setValue("modelSize", size);
    emit modelSizeChanged();
}

bool TranscriptionManager::isProcessing() const { return m_isProcessing; }
QString TranscriptionManager::result() const { return m_result; }
QString TranscriptionManager::statusMessage() const { return m_statusMessage; }

void TranscriptionManager::setIsProcessing(bool v)
{
    if (m_isProcessing == v) return;
    m_isProcessing = v;
    emit isProcessingChanged();
}

void TranscriptionManager::setStatusMessage(const QString &msg)
{
    m_statusMessage = msg;
    emit statusMessageChanged();
}

void TranscriptionManager::setResult(const QString &r)
{
    m_result = r;
    emit resultChanged();
}

QString TranscriptionManager::toLocalPath(const QString &url) const
{
    if (url.startsWith("file:"))
        return QUrl(url).toLocalFile();
    return url;
}

QString TranscriptionManager::getFileName(const QString &fileUrl) const
{
    return QFileInfo(toLocalPath(fileUrl)).fileName();
}

qint64 TranscriptionManager::getFileSize(const QString &fileUrl) const
{
    return QFileInfo(toLocalPath(fileUrl)).size();
}

QString TranscriptionManager::findPython() const
{
    // 1. PATH 上の python / python3
    for (const QString &name : {QString("python"), QString("python3")}) {
        QString found = QStandardPaths::findExecutable(name);
        if (!found.isEmpty()) return found;
    }

    // 2. Windows: %LOCALAPPDATA%\Programs\Python\PythonXXX\python.exe
    QString localAppData = QProcessEnvironment::systemEnvironment().value("LOCALAPPDATA");
    if (!localAppData.isEmpty()) {
        QDir pythonRoot(localAppData + "/Programs/Python");
        if (pythonRoot.exists()) {
            // 新しいバージョンを優先するため降順ソート
            QStringList dirs = pythonRoot.entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name | QDir::Reversed);
            for (const QString &d : dirs) {
                QString candidate = pythonRoot.absoluteFilePath(d + "/python.exe");
                if (QFile::exists(candidate)) return candidate;
            }
        }
    }

    // 3. Windows Store Python (%LOCALAPPDATA%\Microsoft\WindowsApps)
    if (!localAppData.isEmpty()) {
        QString storePy = localAppData + "/Microsoft/WindowsApps/python.exe";
        if (QFile::exists(storePy)) return storePy;
    }

    return {};
}

QString TranscriptionManager::ensureScript() const
{
    QString path = QDir::temp().absoluteFilePath("mp3totxt_transcribe.py");
    QFile f(path);
    if (f.open(QIODevice::WriteOnly | QIODevice::Text)) {
        f.write(TRANSCRIBE_SCRIPT);
        f.close();
    }
    return path;
}

void TranscriptionManager::transcribe(const QString &fileUrl, const QString &language)
{
    if (m_isProcessing) return;

    QString localPath = toLocalPath(fileUrl);
    QFileInfo fi(localPath);

    if (!fi.exists()) {
        emit transcriptionError("ファイルが見つかりません:\n" + localPath);
        return;
    }

    QString scriptPath = ensureScript();

    m_sourceFilePath = localPath;
    setIsProcessing(true);
    setResult("");
    m_accumulatedText.clear();
    m_lastError.clear();
    m_rawOutput.clear();
    setStatusMessage("起動中...");

    QString pythonExe = findPython();
    if (pythonExe.isEmpty()) {
        setIsProcessing(false);
        setStatusMessage("");
        emit transcriptionError(
            "Python が見つかりません。\n"
            "https://www.python.org からインストールしてください。\n\n"
            "インストール後、PATH を通すか Qt Creator を再起動してください。");
        return;
    }

    m_process = new QProcess(this);
    m_process->setProgram(pythonExe);
    m_process->setArguments({scriptPath, localPath, language, m_modelSize});
    m_process->setProcessChannelMode(QProcess::MergedChannels);

    // Windows の Python はデフォルト CP932 → UTF-8 に強制
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert("PYTHONUTF8", "1");
    env.insert("PYTHONIOENCODING", "utf-8");
    m_process->setProcessEnvironment(env);

    connect(m_process, &QProcess::readyReadStandardOutput,
            this, &TranscriptionManager::onProcessReadyRead);
    connect(m_process, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, &TranscriptionManager::onProcessFinished);
    connect(m_process, &QProcess::errorOccurred,
            this, [this, pythonExe](QProcess::ProcessError err) {
        if (err == QProcess::FailedToStart) {
            if (m_process) { m_process->deleteLater(); m_process = nullptr; }
            setIsProcessing(false);
            setStatusMessage("");
            emit transcriptionError("Python の起動に失敗しました:\n" + pythonExe);
        }
    });

    m_process->start(); // ノンブロッキング — UI はフリーズしない
}

void TranscriptionManager::onProcessReadyRead()
{
    if (!m_process) return;
    // readAll で \r (tqdm) も \n も確実に取得する
    const QString output = QString::fromUtf8(m_process->readAll());
    const QStringList lines = output.split(QRegularExpression(R"([\r\n]+)"), Qt::SkipEmptyParts);

    for (const QString &raw : lines) {
        const QString line = raw.trimmed();
        if (line.isEmpty()) continue;

        m_rawOutput += line + "\n";               // 全出力を保存
        if (m_rawOutput.size() > 3000)
            m_rawOutput = m_rawOutput.right(3000); // 直近 3000 文字だけ保持

        if (line.startsWith("STATUS:")) {
            setStatusMessage(line.mid(7));
        } else if (line.startsWith("SEGMENT:")) {
            QString seg = line.mid(8).trimmed();
            if (!seg.isEmpty()) {
                m_accumulatedText += seg;
                // 文末記号の後は段落区切り、それ以外はセグメントごとに改行
                static const QString paraEnds  = QString::fromUtf8("。！？…!?");
                static const QString lineEnds  = QString::fromUtf8("、,");
                QChar last = seg.back();
                if (paraEnds.contains(last))
                    m_accumulatedText += "\n\n";
                else if (lineEnds.contains(last))
                    m_accumulatedText += "\n";
                else
                    m_accumulatedText += "\n";
                setResult(m_accumulatedText.trimmed());
                setStatusMessage("文字起こし中...");
            }
        } else if (line.startsWith("FATAL:")) {
            m_lastError = line.mid(6);
            setStatusMessage("エラー: " + m_lastError);
        }
    }
}

void TranscriptionManager::onProcessFinished(int exitCode, QProcess::ExitStatus exitStatus)
{
    // 残りの出力をすべて吸い上げる
    if (m_process) {
        onProcessReadyRead();
        m_process->deleteLater();
        m_process = nullptr;
    }

    setIsProcessing(false);

    // kill() によるキャンセル
    if (exitStatus == QProcess::CrashExit) {
        setStatusMessage("キャンセルしました");
        return;
    }

    if (exitCode != 0) {
        // FATAL: があればそれを、なければ Python の生出力をそのまま見せる
        QString msg = m_lastError.isEmpty()
            ? QString("終了コード %1\n\n--- Python 出力 ---\n%2")
                  .arg(exitCode).arg(m_rawOutput.trimmed().right(800))
            : m_lastError;
        setStatusMessage("エラー (コード " + QString::number(exitCode) + ")");
        emit transcriptionError(msg);
        return;
    }

    QString finalText = m_accumulatedText.trimmed();
    if (finalText.isEmpty()) {
        setStatusMessage("文字が検出されませんでした");
    } else {
        setResult(finalText);
        setStatusMessage("完了！  " + QString::number(finalText.length()) + " 文字");
        emit transcriptionFinished();
    }
}

void TranscriptionManager::cancelTranscription()
{
    if (m_process) {
        m_process->kill(); // onProcessFinished が CrashExit で呼ばれて後処理する
    }
}

bool TranscriptionManager::saveTxt()
{
    QFileInfo src(m_sourceFilePath);
    QString outPath = src.absoluteDir().absoluteFilePath(src.completeBaseName() + ".txt");

    QFile file(outPath);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text)) {
        emit transcriptionError("保存できませんでした:\n" + outPath);
        return false;
    }
    QTextStream out(&file);
    out.setEncoding(QStringConverter::Utf8);
    out << m_result;
    file.close();
    setStatusMessage("TXT 保存: " + src.completeBaseName() + ".txt");
    return true;
}

bool TranscriptionManager::savePdf()
{
    QFileInfo src(m_sourceFilePath);
    QString outPath = src.absoluteDir().absoluteFilePath(src.completeBaseName() + ".pdf");

    QPdfWriter pdfWriter(outPath);
    pdfWriter.setPageSize(QPageSize(QPageSize::A4));
    pdfWriter.setPageMargins(QMarginsF(20, 20, 20, 20), QPageLayout::Millimeter);
    pdfWriter.setResolution(96);

    QTextDocument doc;
    QFont font;
    font.setPointSize(11);
    doc.setDefaultFont(font);
    doc.setPlainText(m_result);
    doc.setPageSize(QSizeF(pdfWriter.width(), pdfWriter.height()));
    doc.print(&pdfWriter);

    setStatusMessage("PDF 保存: " + src.completeBaseName() + ".pdf");
    return true;
}
