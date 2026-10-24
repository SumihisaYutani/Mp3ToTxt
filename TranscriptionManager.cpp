#include "TranscriptionManager.h"

#include <algorithm>

#include <QCollator>
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
    # 引数: 言語 モデル ファイル一覧(1行1パス, UTF-8)
    # 複数ファイルを1プロセスで順に処理し、モデルの読み込みは1回だけで済ませる
    if len(sys.argv) < 4:
        print("FATAL:引数が不足しています", flush=True)
        sys.exit(1)

    language   = sys.argv[1]
    model_size = sys.argv[2]
    with open(sys.argv[3], encoding="utf-8") as f:
        audio_files = [line.rstrip("\r\n") for line in f if line.strip()]

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
    try:
        from faster_whisper.utils import _MODELS
        repo_id = _MODELS.get(model_size, f"Systran/faster-whisper-{model_size}")
    except Exception:
        repo_id = f"Systran/faster-whisper-{model_size}"
    cache_dir = os.path.join(os.path.expanduser("~"), ".cache", "huggingface", "hub",
                             "models--" + repo_id.replace("/", "--"))
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

    # 日本語は句読点が抜けやすいので、句読点付きの文をプロンプトとして与えて促す
    prompts = {
        "ja": "以下は、日本語の音声を書き起こした文章です。句読点を適切に付けています。",
        "zh": "以下是普通话的句子。",
    }

    for idx, audio_file in enumerate(audio_files):
        print(f"FILE:{idx}", flush=True)
        print("STATUS:音声を解析中...", flush=True)
        try:
            segments, info = model.transcribe(
                audio_file,
                language=lang,
                beam_size=5,
                # 無音・BGM 区間を除去し、幻覚テキストを抑える
                vad_filter=True,
                vad_parameters={"min_silence_duration_ms": 500},
                # 前の誤認識が後ろへ伝染して同じ文を繰り返すのを防ぐ
                condition_on_previous_text=False,
                initial_prompt=prompts.get(lang),
                temperature=[0.0, 0.2, 0.4, 0.6, 0.8, 1.0],
            )
            for segment in segments:
                text = segment.text.strip()
                if text:
                    print(f"SEGMENT:{text}", flush=True)
        except Exception as e:
            # 1ファイルの失敗で残りを止めない
            msg = str(e).replace("\r", " ").replace("\n", " ")
            print(f"FILEERROR:{idx}:文字起こしに失敗しました: {msg}", flush=True)
        print(f"FILEDONE:{idx}", flush=True)

    print("DONE", flush=True)

if __name__ == "__main__":
    main()
)PYTHON";

// -----------------------------------------------------------------------

static const QStringList AUDIO_SUFFIXES = {"mp3", "wav", "m4a", "ogg", "flac", "webm", "mp4"};

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
QString TranscriptionManager::statusMessage() const { return m_statusMessage; }

QString TranscriptionManager::result() const
{
    if (m_selected < 0 || m_selected >= m_items.size()) return {};
    return m_items[m_selected].result;
}

bool TranscriptionManager::isEdited() const
{
    if (m_selected < 0 || m_selected >= m_items.size()) return false;
    const Item &it = m_items[m_selected];
    return !it.original.isEmpty() && it.result != it.original;
}

QVariantList TranscriptionManager::queue() const
{
    static const char *names[] = {"pending", "running", "done", "empty", "error", "cancelled"};
    QVariantList list;
    for (const Item &it : m_items) {
        QVariantMap m;
        m["name"]   = QFileInfo(it.path).fileName();
        m["path"]   = it.path;
        m["status"] = QString::fromLatin1(names[int(it.status)]);
        m["error"]  = it.error;
        m["edited"] = !it.original.isEmpty() && it.result != it.original;
        list << m;
    }
    return list;
}

int TranscriptionManager::selectedIndex() const { return m_selected; }

void TranscriptionManager::selectIndex(int index)
{
    if (index < -1 || index >= m_items.size() || index == m_selected) return;
    m_selected = index;
    emit selectedIndexChanged();
    emit resultChanged();
}

bool TranscriptionManager::editing() const { return m_editing; }

void TranscriptionManager::setEditing(bool v)
{
    if (m_editing == v) return;
    m_editing = v;
    emit editingChanged();
}

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

void TranscriptionManager::setItemStatus(int index, Status status)
{
    m_items[index].status = status;
    emit queueChanged();
}

// 複数ファイル処理中は "[2/5] " を返す（1件だけなら空）
QString TranscriptionManager::progressText() const
{
    if (m_batch.size() <= 1 || m_running < 0) return {};
    return QString("[%1/%2] ").arg(m_batch.indexOf(m_running) + 1).arg(m_batch.size());
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

int TranscriptionManager::setSources(const QList<QUrl> &urls)
{
    if (m_isProcessing || m_editing) return 0;

    QStringList nameFilters;
    for (const QString &s : AUDIO_SUFFIXES) nameFilters << "*." + s;

    QStringList files;
    for (const QUrl &url : urls) {
        QFileInfo fi(url.isLocalFile() ? url.toLocalFile() : url.toString());
        if (fi.isDir()) {
            QDir dir(fi.absoluteFilePath());
            for (const QString &name : dir.entryList(nameFilters, QDir::Files))
                files << dir.absoluteFilePath(name);
        } else if (fi.isFile() && AUDIO_SUFFIXES.contains(fi.suffix().toLower())) {
            files << fi.absoluteFilePath();
        }
    }
    files.removeDuplicates();

    if (files.isEmpty()) {
        emit transcriptionError("音声ファイルが見つかりませんでした。\n対応形式: "
                                + AUDIO_SUFFIXES.join(" / ").toUpper());
        return 0;
    }

    // 「第2回」が「第10回」より前に来るよう、数字を数値として比較する
    QCollator collator;
    collator.setNumericMode(true);
    collator.setCaseSensitivity(Qt::CaseInsensitive);
    std::sort(files.begin(), files.end(), collator);

    m_items.clear();
    for (const QString &f : files) {
        Item it;
        it.path = f;
        m_items << it;
    }
    m_selected = 0;
    emit queueChanged();
    emit selectedIndexChanged();
    emit resultChanged();
    setStatusMessage(files.size() > 1 ? QString("%1 件のファイルを読み込みました").arg(files.size()) : QString());
    return files.size();
}

void TranscriptionManager::start(const QString &language)
{
    if (m_isProcessing || m_items.isEmpty()) return;

    // 未完了のファイルだけを処理する（完了済みの結果と修正は残す）。
    // すべて完了済みなら、全件をやり直す。
    auto finished = [](const Item &it) { return it.status == Status::Done || it.status == Status::Empty; };
    const bool allFinished = std::all_of(m_items.cbegin(), m_items.cend(), finished);

    m_batch.clear();
    for (int i = 0; i < m_items.size(); ++i) {
        Item &it = m_items[i];
        if (!allFinished && finished(it)) continue;
        if (!QFileInfo::exists(it.path)) {
            it.status = Status::Error;
            it.error = "ファイルが見つかりません: " + it.path;
            continue;
        }
        it.status = Status::Pending;
        it.result.clear();
        it.original.clear();
        it.error.clear();
        m_batch << i;
    }
    emit queueChanged();
    emit resultChanged();

    if (m_batch.isEmpty()) {
        emit transcriptionError("処理できるファイルがありません。");
        return;
    }

    QString pythonExe = findPython();
    if (pythonExe.isEmpty()) {
        emit transcriptionError(
            "Python が見つかりません。\n"
            "https://www.python.org からインストールしてください。\n\n"
            "インストール後、PATH を通すか Qt Creator を再起動してください。");
        return;
    }

    // ファイル一覧は引数ではなくファイルで渡す（大量のファイルでもコマンドライン長の上限に当たらない）
    QString listPath = QDir::temp().absoluteFilePath("mp3totxt_files.txt");
    QFile listFile(listPath);
    if (!listFile.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        emit transcriptionError("一時ファイルを作成できませんでした:\n" + listPath);
        return;
    }
    for (int i : m_batch)
        listFile.write(QDir::toNativeSeparators(m_items[i].path).toUtf8() + "\n");
    listFile.close();

    QString scriptPath = ensureScript();

    m_running = -1;
    m_lastError.clear();
    m_rawOutput.clear();
    if (!m_editing) selectIndex(m_batch.first());
    setIsProcessing(true);
    setStatusMessage("起動中...");

    m_process = new QProcess(this);
    m_process->setProgram(pythonExe);
    m_process->setArguments({scriptPath, language, m_modelSize, listPath});
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

void TranscriptionManager::appendSegment(int index, const QString &seg)
{
    QString &text = m_items[index].result;
    text += seg;
    // 文末記号の後は段落区切り、それ以外はセグメントごとに改行
    static const QString paraEnds = QString::fromUtf8("。！？…!?");
    text += paraEnds.contains(seg.back()) ? "\n\n" : "\n";
    if (index == m_selected) emit resultChanged();
}

void TranscriptionManager::finishItem(int index)
{
    if (index < 0) return;
    Item &it = m_items[index];
    it.result = it.result.trimmed();
    if (!it.error.isEmpty()) {
        it.status = Status::Error;
    } else if (it.result.isEmpty()) {
        it.status = Status::Empty;
    } else {
        it.status = Status::Done;
        it.original = it.result;
    }
    emit queueChanged();
    if (index == m_selected) emit resultChanged();
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

        if (line.startsWith("FILE:")) {
            int pos = line.mid(5).toInt();
            if (pos < 0 || pos >= m_batch.size()) continue;
            int prev = m_running;
            m_running = m_batch[pos];
            setItemStatus(m_running, Status::Running);
            // 直前のファイルの経過を見ていたなら、次のファイルへ表示を移す
            if (!m_editing && m_selected == prev) selectIndex(m_running);
        } else if (line.startsWith("FILEDONE:")) {
            finishItem(m_running);
        } else if (line.startsWith("FILEERROR:")) {
            // FILEERROR:<番号>:<メッセージ>
            const QString rest = line.mid(10);
            if (m_running >= 0)
                m_items[m_running].error = rest.mid(rest.indexOf(':') + 1);
        } else if (line.startsWith("STATUS:")) {
            setStatusMessage(progressText() + line.mid(7));
        } else if (line.startsWith("SEGMENT:")) {
            QString seg = line.mid(8).trimmed();
            if (!seg.isEmpty() && m_running >= 0) {
                appendSegment(m_running, seg);
                setStatusMessage(progressText() + "文字起こし中...");
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

    const bool cancelled = exitStatus == QProcess::CrashExit; // kill() によるキャンセル

    // 途中で止まったファイルを整理（未着手のファイルは待機のまま残し、次回の開始で続きから処理する）
    for (int i : m_batch) {
        Item &it = m_items[i];
        if (it.status != Status::Running) continue;
        if (cancelled) {
            it.status = Status::Cancelled;
        } else {
            it.status = Status::Error;
            if (it.error.isEmpty())
                it.error = m_lastError.isEmpty() ? QString("処理が途中で終了しました") : m_lastError;
        }
    }
    m_running = -1;
    emit queueChanged();
    emit resultChanged();
    setIsProcessing(false);

    if (cancelled) {
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

    int done = 0, empty = 0, failed = 0;
    for (int i : m_batch) {
        switch (m_items[i].status) {
        case Status::Done:  ++done;   break;
        case Status::Empty: ++empty;  break;
        default:            ++failed; break;
        }
    }

    if (m_batch.size() == 1) {
        const Item &it = m_items[m_batch.first()];
        if (it.status == Status::Done) {
            setStatusMessage("完了！  " + QString::number(it.result.length()) + " 文字");
        } else if (it.status == Status::Empty) {
            setStatusMessage("文字が検出されませんでした");
        } else {
            setStatusMessage("エラー");
            emit transcriptionError(it.error);
        }
    } else {
        QString msg = QString("完了！  %1 件中 %2 件").arg(m_batch.size()).arg(done);
        if (empty)  msg += QString(" / 文字なし %1 件").arg(empty);
        if (failed) msg += QString(" / エラー %1 件").arg(failed);
        setStatusMessage(msg);
    }
    if (done > 0) emit transcriptionFinished();
}

void TranscriptionManager::cancelTranscription()
{
    if (m_process) {
        m_process->kill(); // onProcessFinished が CrashExit で呼ばれて後処理する
    }
}

void TranscriptionManager::applyEdit(const QString &text)
{
    if (m_selected < 0 || m_selected >= m_items.size()) return;
    Item &it = m_items[m_selected];
    if (it.status != Status::Done) return;
    it.result = text;
    emit resultChanged();
    emit queueChanged();
    setStatusMessage(isEdited() ? "修正を反映しました" : "修正なし");
}

void TranscriptionManager::revertEdits()
{
    if (m_selected < 0 || m_selected >= m_items.size()) return;
    Item &it = m_items[m_selected];
    if (it.status != Status::Done || it.original.isEmpty()) return;
    it.result = it.original;
    emit resultChanged();
    emit queueChanged();
    setStatusMessage("文字起こし直後の内容に戻しました");
}

bool TranscriptionManager::writeTxt(int index)
{
    const Item &it = m_items[index];
    QFileInfo src(it.path);
    QString outPath = src.absoluteDir().absoluteFilePath(src.completeBaseName() + ".txt");

    QFile file(outPath);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text)) {
        emit transcriptionError("保存できませんでした:\n" + outPath);
        return false;
    }
    QTextStream out(&file);
    out.setEncoding(QStringConverter::Utf8);
    out << it.result;
    file.close();
    return true;
}

bool TranscriptionManager::writePdf(int index)
{
    const Item &it = m_items[index];
    QFileInfo src(it.path);
    QString outPath = src.absoluteDir().absoluteFilePath(src.completeBaseName() + ".pdf");

    QPdfWriter pdfWriter(outPath);
    pdfWriter.setPageSize(QPageSize(QPageSize::A4));
    pdfWriter.setPageMargins(QMarginsF(20, 20, 20, 20), QPageLayout::Millimeter);
    pdfWriter.setResolution(96);

    QTextDocument doc;
    QFont font;
    font.setPointSize(11);
    doc.setDefaultFont(font);
    doc.setPlainText(it.result);
    doc.setPageSize(QSizeF(pdfWriter.width(), pdfWriter.height()));
    doc.print(&pdfWriter);
    return true;
}

bool TranscriptionManager::saveTxt()
{
    if (m_selected < 0 || m_selected >= m_items.size() || m_items[m_selected].status != Status::Done)
        return false;
    if (!writeTxt(m_selected)) return false;
    setStatusMessage("TXT 保存: " + QFileInfo(m_items[m_selected].path).completeBaseName() + ".txt");
    return true;
}

bool TranscriptionManager::savePdf()
{
    if (m_selected < 0 || m_selected >= m_items.size() || m_items[m_selected].status != Status::Done)
        return false;
    if (!writePdf(m_selected)) return false;
    setStatusMessage("PDF 保存: " + QFileInfo(m_items[m_selected].path).completeBaseName() + ".pdf");
    return true;
}

int TranscriptionManager::saveAllTxt()
{
    int saved = 0;
    for (int i = 0; i < m_items.size(); ++i)
        if (m_items[i].status == Status::Done && writeTxt(i)) ++saved;
    setStatusMessage(QString("%1 件を TXT で保存しました（各音声ファイルと同じフォルダ）").arg(saved));
    return saved;
}

int TranscriptionManager::saveAllPdf()
{
    int saved = 0;
    for (int i = 0; i < m_items.size(); ++i)
        if (m_items[i].status == Status::Done && writePdf(i)) ++saved;
    setStatusMessage(QString("%1 件を PDF で保存しました（各音声ファイルと同じフォルダ）").arg(saved));
    return saved;
}
