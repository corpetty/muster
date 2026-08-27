// muster_headless_host — a headless, in-process logos-core host for driving
// muster_module (+ its delivery_module dependency) with the capability gate OFF
// (set_access_policy(nullptr)), coherent with muster's own build. It exposes a
// tiny stdin REPL: each line is `<module>\t<method>\t<arg1>\t<arg2>...`; the call
// is invoked synchronously and its result printed as one line prefixed `OK\t` or
// `ERR\t`. The Qt event loop keeps running between calls so delivery's async
// transport pumps — which is exactly what a two-instance live run needs.
#include <QCoreApplication>
#include <QSocketNotifier>
#include <QVariant>
#include <QVariantList>
#include <QStringList>
#include <QTextStream>
#include <cstdio>
#include <QElapsedTimer>
#include <QEventLoop>

#include "logos_core.h"
#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_call_error.h"
#include "logos_transport_config.h"
#include "logos_transport_config_json.h"

int main(int argc, char** argv)
{
    QCoreApplication app(argc, argv);
    QString modulesDir, persist, loadModule = "muster_module";
    const QStringList a = app.arguments();
    for (int i = 1; i < a.size(); ++i) {
        if (a[i] == "--modules-dir" && i + 1 < a.size()) modulesDir = a[++i];
        else if (a[i] == "--persistence" && i + 1 < a.size()) persist = a[++i];
        else if (a[i] == "--load" && i + 1 < a.size()) loadModule = a[++i];
    }

    // In-process, capability gate OFF (the standalone app's model) — no
    // cross-process token handshake, so muster's calls to delivery just work.
    logos_core_set_access_policy(nullptr);
    if (!modulesDir.isEmpty()) logos_core_add_modules_dir(modulesDir.toUtf8().constData());
    if (!persist.isEmpty())    logos_core_set_persistence_base_path(persist.toUtf8().constData());
    {
        LogosTransportSet localSet = { LogosTransportConfig{} };   // one LocalSocket entry
        const std::string j = logos::transportSetToJsonString(localSet);
        for (const char* m : {"capability_module", "muster_module", "delivery_module"})
            logos_core_set_module_transports(m, j.c_str());
    }
    logos_core_start();
    const int loaded = logos_core_load_module(loadModule.toUtf8().constData(), true);
    fprintf(stderr, "[host] load %s -> %d\n", loadModule.toUtf8().constData(), loaded);
    fflush(stderr);
    { QElapsedTimer t; t.start(); while (t.elapsed() < 4000) app.processEvents(QEventLoop::AllEvents, 100); }
    fprintf(stderr, "[host] settled; ready\n"); fflush(stderr);

    static LogosAPI logosAPI("core", nullptr);

    // stdin REPL — one call per line, tab-separated. Prints OK/ERR + result.
    auto* notifier = new QSocketNotifier(fileno(stdin), QSocketNotifier::Read, &app);
    QObject::connect(notifier, &QSocketNotifier::activated, [&]() {
        QTextStream in(stdin);
        const QString line = in.readLine();
        if (line.isNull()) { app.quit(); return; }
        const QString t = line.trimmed();
        if (t.isEmpty()) return;
        if (t == "quit" || t == "exit") { app.quit(); return; }
        const QStringList parts = t.split(QChar('\t'));
        if (parts.size() < 2) { printf("ERR\tbad-line\n"); fflush(stdout); return; }
        const QString module = parts[0];
        const QString method = parts[1];
        QVariantList args;
        for (int i = 2; i < parts.size(); ++i) args << parts[i];
        LogosAPIClient* client = logosAPI.getClient(module);
        if (!client) { printf("ERR\tno-client\n"); fflush(stdout); return; }
        logos::CallError err;
        const QVariant r = client->invokeRemoteMethod(module, method, args, Timeout(), &err);
        if (err.ok() && r.isValid()) printf("OK\t%s\n", r.toString().toUtf8().constData());
        else printf("ERR\t%s\t%s\n", err.code.c_str(), err.message.c_str());
        fflush(stdout);
    });

    QObject::connect(&app, &QCoreApplication::aboutToQuit, []() { logos_core_cleanup(); });
    return app.exec();
}
