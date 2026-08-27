// muster_headless_host — a headless, in-process logos-core host for driving
// muster_module (+ its delivery_module dependency) with the capability gate OFF,
// coherent with muster's own build. Stdin REPL: `<module>\t<method>\t<arg1>...`;
// prints `OK\t<result>` / `ERR\t...`. The Qt event loop runs between calls so
// delivery's async transport pumps — what a two-instance live run needs.
//
// Invocation uses raw QRemoteObjects: the module publishes its object in a per-instance
// registry (local:logos_<module>_<LOGOS_INSTANCE_ID>); we acquire the dynamic replica +
// call its ModuleProxy dispatch callRemoteMethod(token, method, args). Replicas are
// pre-acquired at startup (acquiring inside the stdin callback hits QRemoteObjects
// nested-event-loop re-entrancy). The LogosAPIClient wrapper's own requestObject fails
// headless where a plain node succeeds, so we bypass it.
#include <QCoreApplication>
#include <QSocketNotifier>
#include <QTimer>
#include <QVariant>
#include <QVariantList>
#include <QStringList>
#include <QTextStream>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QUrl>
#include <QMap>
#include <QRemoteObjectNode>
#include <QRemoteObjectDynamicReplica>
#include <QRemoteObjectReplica>
#include <QRemoteObjectPendingCall>
#include <QRemoteObjectPendingCallWatcher>
#include <cstdio>
#include <cstdlib>

#include "logos_core.h"

static QMap<QString, QRemoteObjectNode*> g_nodes;
static QMap<QString, QRemoteObjectDynamicReplica*> g_reps;
// Protocol replies go here, never to stdout — the loaded modules (delivery in
// particular) write their own node logs to stdout with no newline sync, so an
// "OK\t..." printed there can land mid-log-line. A dedicated line-buffered stream
// keeps the reply channel clean. Defaults to stdout when --reply-file is absent.
static FILE* g_reply = stdout;
static void reply(const char* s) { fputs(s, g_reply); fflush(g_reply); }

static QRemoteObjectDynamicReplica* acquireModule(const QString& module, int timeoutMs)
{
    if (g_reps.contains(module)) return g_reps[module];
    const QString inst = QString::fromUtf8(qgetenv("LOGOS_INSTANCE_ID"));
    auto* node = new QRemoteObjectNode();
    node->setRegistryUrl(QUrl(QString("local:logos_%1_%2").arg(module).arg(inst)));
    auto* rep = node->acquireDynamic(module);
    rep->waitForSource(timeoutMs);
    g_nodes[module] = node;
    g_reps[module] = rep;
    fprintf(stderr, "[host] acquire %s -> state=%d\n", module.toUtf8().constData(), (int)rep->state());
    fflush(stderr);
    return rep;
}

static void handleLine(const QString& line)
{
    const QString t = line.trimmed();
    if (t.isEmpty()) return;
    const QStringList parts = t.split(QChar('\t'));
    if (parts.size() < 2) { reply("ERR\tbad-line\n"); return; }
    const QString module = parts[0];
    const QString method = parts[1];
    QVariantList args;
    for (int i = 2; i < parts.size(); ++i) args << parts[i];

    QRemoteObjectDynamicReplica* rep = g_reps.value(module, nullptr);
    if (!rep || rep->state() != QRemoteObjectReplica::Valid) {
        { QByteArray m=module.toUtf8(); QByteArray b="ERR\tobject_unavailable\t"+m+"\n"; reply(b.constData()); } return;
    }
    // The ModuleProxy accepts any issued token; use the one the core minted for this
    // module (auth policy is off, so it need only be recognized, not scoped).
    char* tok = logos_core_get_token(module.toUtf8().constData());
    const QString token = tok ? QString::fromUtf8(tok) : QString();
    if (tok) free(tok);
    QRemoteObjectPendingCall call;
    const bool inv = QMetaObject::invokeMethod(
        rep, "callRemoteMethod", Qt::DirectConnection,
        Q_RETURN_ARG(QRemoteObjectPendingCall, call),
        Q_ARG(QString, token), Q_ARG(QString, method), Q_ARG(QVariantList, args));
    if (!inv) { reply("ERR\tinvoke-failed\n"); return; }
    // Fully async — a nested waitForFinished inside app.exec() mis-delivers the QRO
    // reply; the watcher fires from the main loop instead.
    auto* w = new QRemoteObjectPendingCallWatcher(call);
    QObject::connect(w, &QRemoteObjectPendingCallWatcher::finished, [w]() {
        if (w->error() == QRemoteObjectPendingCall::NoError) {
            QByteArray b="OK\t"+w->returnValue().toString().toUtf8()+"\n"; reply(b.constData());
        } else {
            reply("ERR\tpending-error\n");
        }
        w->deleteLater();
    });
}

int main(int argc, char** argv)
{
    QByteArray inst = "muster-headless";
    QString modulesDir, persist, loadModule = "muster_module", replyFile;
    for (int i = 1; i < argc; ++i) {
        const QString a = QString::fromUtf8(argv[i]);
        if      (a == "--instance"    && i + 1 < argc) inst = argv[++i];
        else if (a == "--modules-dir" && i + 1 < argc) modulesDir = QString::fromUtf8(argv[++i]);
        else if (a == "--persistence" && i + 1 < argc) persist = QString::fromUtf8(argv[++i]);
        else if (a == "--load"        && i + 1 < argc) loadModule = QString::fromUtf8(argv[++i]);
        else if (a == "--reply-file"  && i + 1 < argc) replyFile = QString::fromUtf8(argv[++i]);
    }
    qputenv("LOGOS_INSTANCE_ID", inst);
    if (!replyFile.isEmpty()) {
        FILE* f = fopen(replyFile.toUtf8().constData(), "w");
        if (f) g_reply = f;  // clean protocol channel, away from delivery's stdout logs
    }

    QCoreApplication app(argc, argv);
    logos_core_init(argc, argv);
    logos_core_set_access_policy(nullptr);
    if (!modulesDir.isEmpty()) logos_core_add_modules_dir(modulesDir.toUtf8().constData());
    if (!persist.isEmpty())    logos_core_set_persistence_base_path(persist.toUtf8().constData());
    logos_core_start();
    const int loaded = logos_core_load_module(loadModule.toUtf8().constData(), true);
    fprintf(stderr, "[host] load %s -> %d\n", loadModule.toUtf8().constData(), loaded);
    fflush(stderr);

    { QElapsedTimer t; t.start(); while (t.elapsed() < 4000) app.processEvents(QEventLoop::AllEvents, 100); }
    acquireModule("muster_module", 15000);
    // Also acquire delivery_module (loaded as muster's dependency) so the driver can
    // read node multiaddrs (getNodeInfo) for two-instance peering. Non-fatal if absent.
    acquireModule("delivery_module", 8000);
    fprintf(stderr, "[host] ready\n"); fflush(stderr);

    auto* notifier = new QSocketNotifier(fileno(stdin), QSocketNotifier::Read, &app);
    QObject::connect(notifier, &QSocketNotifier::activated, [&]() {
        QTextStream in(stdin);
        const QString line = in.readLine();
        if (line.isNull()) { app.quit(); return; }
        if (line.trimmed() == "quit" || line.trimmed() == "exit") { app.quit(); return; }
        QTimer::singleShot(0, [line]() { handleLine(line); });
    });
    QObject::connect(&app, &QCoreApplication::aboutToQuit, []() { logos_core_cleanup(); });
    return app.exec();
}
