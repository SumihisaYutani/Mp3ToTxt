#include "TranscriptionManager.h"

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    app.setOrganizationName("Mp3ToTxt");
    app.setApplicationName("Mp3ToTxt");

    TranscriptionManager transcriptionManager;

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("transcriptionManager", &transcriptionManager);

    QObject::connect(
        &engine,
        &QQmlApplicationEngine::objectCreationFailed,
        &app,
        []() { QCoreApplication::exit(-1); },
        Qt::QueuedConnection);
    engine.loadFromModule("Mp3ToTxt", "Main");

    return app.exec();
}
