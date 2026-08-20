// Host client harness for derived-exo-526 (companion to
// probe_return_marshalling_host.nim). It links the module's Nim staticlib
// (the REAL Nim core — no mock) and drives it through the SAME return-marshalling
// the shipped host applies, so the value it prints is what a host CLIENT observes,
// not the raw logos_module_dispatch string.
//
// The marshalling reproduced here is exactly the shipped cdylib path:
//   * logos-qt-sdk qt-generator/lidl_gen_cdylib_glue.cpp  (the generated
//     <Module>CdylibProvider::callMethod): dispatch -> nlohmann::json::parse
//     -> logos::nlohmannToQVariant(jResult).
//   * logos-cpp-sdk cpp/logos_json_convert.cpp nlohmannToQVariant(): a JSON
//     string becomes QVariant(QString); a JSON bool becomes QVariant(bool);
//     null/discarded becomes an invalid QVariant.
//   * logos-liblogos src/logos_core/proxy_api.cpp (--call): the CLI reads the
//     returned QVariant as `canConvert<QString>() ? toString() : "Result of
//     type: <T>"`. A bool false thus prints the literal "false" — the exact
//     symptom this probe exists to catch.
//
// Qt / nlohmann are not on the probe's bare-nim toolchain, so the JSON-scalar
// -> typed-value -> client-string reduction is reimplemented minimally over the
// dispatch output. It is not a re-encode of the module's answer: it parses the
// module's real dispatch bytes and classifies the client-observed type, which is
// where the reported bool-drop would surface.
//
// Emits one JSON observation object per call on stdout; it JUDGES NOTHING — the
// probe (and the spec's `always(client_return_typed)`) own every verdict.

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

extern "C" {
  void NimMain(void);
  char* logos_module_dispatch(const char* meth, const char* argsJson);
  char* logos_module_get_methods();
  void  logos_module_string_free(const char* s);
}

namespace {

// The three client-observed shapes the reduction can land on. `String` is the
// only typed-string outcome a QString-returning method should ever produce;
// `Bool` is the reported regression (QVariant(bool) -> CLI "true"/"false");
// `Empty` is a dropped/invalid QVariant (null/parse-failure -> CLI "").
enum class ClientType { String, Bool, Empty, Number, Other };

const char* typeName(ClientType t) {
  switch (t) {
    case ClientType::String: return "string";
    case ClientType::Bool:   return "bool";
    case ClientType::Empty:  return "empty";
    case ClientType::Number: return "number";
    default:                 return "other";
  }
}

// A minimal model of the shipped path nlohmannToQVariant + CLI stringify for a
// scalar JSON return. `raw` is the exact bytes logos_module_dispatch returned.
struct ClientReturn {
  ClientType type;
  std::string value;  // the string the CLI would print (QVariant::toString())
};

std::string jsonEscape(const std::string& s) {
  std::string o;
  for (char c : s) {
    switch (c) {
      case '"':  o += "\\\""; break;
      case '\\': o += "\\\\"; break;
      case '\n': o += "\\n";  break;
      case '\t': o += "\\t";  break;
      case '\r': o += "\\r";  break;
      default:   o += c;      break;
    }
  }
  return o;
}

// Decode a JSON string literal body (assumes leading/trailing quotes stripped).
std::string decodeJsonString(const std::string& body) {
  std::string o;
  for (size_t i = 0; i < body.size(); ++i) {
    if (body[i] == '\\' && i + 1 < body.size()) {
      char n = body[++i];
      switch (n) {
        case 'n': o += '\n'; break;
        case 't': o += '\t'; break;
        case 'r': o += '\r'; break;
        case '"': o += '"';  break;
        case '\\': o += '\\'; break;
        case '/': o += '/';  break;
        default:  o += n;    break;
      }
    } else {
      o += body[i];
    }
  }
  return o;
}

// Reproduce the host: parse the dispatch scalar JSON and classify the QVariant
// the client observes, then the string the CLI prints from it. This is the
// nlohmannToQVariant + proxy_api.cpp `toString()` reduction, no more.
ClientReturn hostObserve(const char* raw) {
  if (!raw) return { ClientType::Empty, "" };            // null dispatch -> QVariant() -> ""
  std::string r(raw);
  // Trim surrounding ASCII whitespace, matching JSON parse tolerance.
  size_t a = 0, b = r.size();
  while (a < b && (r[a] == ' ' || r[a] == '\n' || r[a] == '\t' || r[a] == '\r')) ++a;
  while (b > a && (r[b-1] == ' ' || r[b-1] == '\n' || r[b-1] == '\t' || r[b-1] == '\r')) --b;
  std::string t = r.substr(a, b - a);
  if (t.empty() || t == "null")   return { ClientType::Empty, "" };
  if (t == "true")                return { ClientType::Bool, "true" };
  if (t == "false")               return { ClientType::Bool, "false" };
  if (t.size() >= 2 && t.front() == '"' && t.back() == '"')
    return { ClientType::String, decodeJsonString(t.substr(1, t.size() - 2)) };
  // A bare number token.
  bool numeric = true;
  for (char c : t) if (!(c == '-' || c == '+' || c == '.' || (c >= '0' && c <= '9'))) { numeric = false; break; }
  if (numeric) return { ClientType::Number, t };
  return { ClientType::Other, t };
}

// Call one method through the module's C ABI and reduce to a client return.
ClientReturn callClient(const std::string& method, const std::string& argsJson) {
  char* raw = logos_module_dispatch(method.c_str(), argsJson.c_str());
  ClientReturn cr = hostObserve(raw);
  if (raw) logos_module_string_free(raw);
  return cr;
}

// Emit one observation line. `expect` is the declared-typed contract for this
// call: "ok" for health, "nonempty_id" for propose, "state_token" for status.
void emit(const std::string& call, const std::string& expect, const ClientReturn& cr) {
  // A QString-returning method is typed iff the client observed a non-empty
  // STRING (never bool, never empty/default). status() must additionally be a
  // known lifecycle token; propose() a non-empty id.
  bool typed = (cr.type == ClientType::String) && !cr.value.empty();
  if (typed && expect == "ok")           typed = (cr.value == "ok");
  if (typed && expect == "state_token") {
    static const char* tokens[] = {
      "draft", "proposed", "collecting", "executable", "final",
      "expired", "aborted", "unknown-intent"
    };
    bool known = false;
    for (const char* tk : tokens) if (cr.value == tk) { known = true; break; }
    typed = known;
  }
  printf("{\"call\": \"%s\", \"expect\": \"%s\", \"client_type\": \"%s\", "
         "\"client_value\": \"%s\", \"client_return_typed\": %s}\n",
         jsonEscape(call).c_str(), jsonEscape(expect).c_str(),
         typeName(cr.type), jsonEscape(cr.value).c_str(),
         typed ? "true" : "false");
}

std::string quoteArg(const std::string& effectJson) {
  // Build a JSON args array ["<effectJson>"] with effectJson escaped as a string.
  return std::string("[\"") + jsonEscape(effectJson) + "\"]";
}

}  // namespace

int main() {
  NimMain();  // initialize the Nim runtime of the staticlib (the host's ctor does this)

  // health(): the canonical liveness return; must be exactly "ok".
  emit("health", "ok", callClient("health", "[]"));

  // propose() across a family of valid/edge effect JSONs, then status() of each
  // resulting id. The edge cases exercise the impl's JSON tolerance without ever
  // being allowed to collapse the typed string return to a bool/empty default.
  const std::vector<std::string> effects = {
    "{\"to\":\"0xabc\",\"value\":1000,\"nonce\":0}",   // canonical transfer
    "{\"to\":\"0x0\",\"value\":0,\"nonce\":0}",         // zero value/addr
    "{\"to\":\"0xffffffffffffffffffffffffffffffffffffffff\",\"value\":1,\"nonce\":7}",
    "{}",                                                // empty object (no fields)
    "{\"value\":42}",                                    // partial object
    "not json at all",                                   // malformed effect
    "{\"to\":\"0xabc\",\"value\":1000,\"nonce\":0,\"extra\":\"ignored\"}",
  };
  for (const std::string& eff : effects) {
    ClientReturn pr = callClient("propose", quoteArg(eff));
    emit("propose", "nonempty_id", pr);
    // status(<the id>) — reuse the client-observed id string as the argument.
    std::string idArg = std::string("[\"") + jsonEscape(pr.value) + "\"]";
    emit("status", "state_token", callClient("status", idArg));
  }
  return 0;
}
