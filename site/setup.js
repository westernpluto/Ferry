// "Sign with your certificate": reads your .p12 and profile in the browser, encrypts
// them for GitHub (sealed boxes), saves them as secrets in *your* copy of Ferry, starts
// its Install page workflow and follows it until your signed build is published.
//
// Private mode (the default) also saves a random INSTALL_KEY: the signed app is then
// published under i/<key>/ on your page, reachable only with the link shown here, and
// taken down again after the time you pick. With "Delete … after signing" the secrets
// are removed once the build has used them.
//
// Nothing is stored except the name of your copy (localStorage), and nothing is sent
// anywhere except api.github.com.
(function () {
  "use strict";

  var API = "https://api.github.com";
  var WORKFLOW = "pages.yml";
  var SECRET_NAMES = ["SIGNING_CERTIFICATE_P12", "SIGNING_CERTIFICATE_PASSWORD", "PROVISIONING_PROFILE", "INSTALL_KEY"];
  var $ = function (id) { return document.getElementById(id); };

  var profileInfo = null;

  // ---- Repositories -----------------------------------------------------------------
  /// The repository this page is published from (owner.github.io/<repo>/).
  function siteRepository() {
    var host = location.hostname;
    if (!/\.github\.io$/i.test(host)) return "";
    var owner = host.split(".")[0];
    var first = location.pathname.split("/").filter(Boolean)[0];
    return owner + "/" + (first || owner + ".github.io");
  }

  function storedRepository() {
    try { return localStorage.getItem("ferry.repo") || ""; } catch (e) { return ""; }
  }

  function rememberRepository(repo) {
    try { localStorage.setItem("ferry.repo", repo); } catch (e) { /* private browsing */ }
  }

  function sameSite(url) {
    var here = location.origin + location.pathname.replace(/[^/]*$/, "");
    return url.toLowerCase() === here.toLowerCase();
  }

  // ---- Files ---------------------------------------------------------------------
  function readFile(input) {
    return new Promise(function (resolve, reject) {
      var file = input.files && input.files[0];
      if (!file) return reject(new Error("Choose your " + (input.id === "p12" ? ".p12" : "profile") + " first."));
      var reader = new FileReader();
      reader.onload = function () { resolve(new Uint8Array(reader.result)); };
      reader.onerror = function () { reject(new Error("Couldn't read " + file.name + ".")); };
      reader.readAsArrayBuffer(file);
    });
  }

  function plistValue(node) {
    switch (node.tagName) {
      case "dict":
        var result = {};
        var children = Array.prototype.filter.call(node.childNodes, function (n) { return n.nodeType === 1; });
        for (var i = 0; i + 1 < children.length; i += 2) result[children[i].textContent] = plistValue(children[i + 1]);
        return result;
      case "array":
        return Array.prototype.filter.call(node.childNodes, function (n) { return n.nodeType === 1; }).map(plistValue);
      case "true": return true;
      case "false": return false;
      case "integer": return parseInt(node.textContent, 10);
      case "real": return parseFloat(node.textContent);
      case "date": return new Date(node.textContent);
      default: return node.textContent.trim();
    }
  }

  /// Pulls the XML property list out of the signed (CMS) profile.
  function parseProfile(bytes) {
    var text = "";
    for (var i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    var start = text.indexOf("<?xml");
    var end = text.indexOf("</plist>", start);
    if (start < 0 || end < 0) throw new Error("That doesn't look like a .mobileprovision file.");
    var xml = new DOMParser().parseFromString(text.slice(start, end + 8), "application/xml");
    var root = xml.querySelector("plist > dict");
    if (!root) throw new Error("The profile couldn't be read.");
    var plist = plistValue(root);
    var entitlements = plist.Entitlements || {};
    var appID = entitlements["application-identifier"] || "";
    var dot = appID.indexOf(".");
    var pattern = dot >= 0 ? appID.slice(dot + 1) : "";
    var kind = plist.ProvisionsAllDevices ? "Enterprise"
      : plist.ProvisionedDevices ? (entitlements["get-task-allow"] ? "Development" : "Ad Hoc")
      : "App Store";
    var defaultBundleID = pattern.slice(-1) === "*"
      ? (pattern.length > 1 ? pattern.slice(0, -1) + "ferry" : "com.example.Ferry")
      : pattern;
    return {
      name: plist.Name || "Profile",
      team: plist.TeamName || (plist.TeamIdentifier || [])[0] || "",
      pattern: pattern,
      kind: kind,
      expires: plist.ExpirationDate instanceof Date ? plist.ExpirationDate : null,
      devices: plist.ProvisionedDevices ? plist.ProvisionedDevices.length : null,
      defaultBundleID: defaultBundleID,
      covers: function (id) {
        return pattern.slice(-1) === "*" ? id.indexOf(pattern.slice(0, -1)) === 0 : id === pattern;
      },
    };
  }

  function showProfile(info, error) {
    var box = $("profile-summary");
    box.hidden = false;
    box.className = "note" + (error ? " warn" : "");
    if (error) { box.textContent = error; return; }
    var problems = [];
    if (info.kind === "App Store") problems.push("This is an App Store profile. Use Development, Ad Hoc or Enterprise.");
    if (info.expires && info.expires <= new Date()) problems.push("This profile has expired.");
    box.textContent = info.name + " · " + info.kind + (info.team ? " · " + info.team : "") +
      " · App ID " + (info.pattern || "?") +
      (info.devices !== null ? " · " + info.devices + " devices" : "") +
      (info.expires ? " · expires " + info.expires.toISOString().slice(0, 10) : "");
    if (problems.length) {
      box.className = "note warn";
      box.textContent += "\n" + problems.join(" ");
    }
    $("bundle-id").placeholder = info.defaultBundleID || "com.you.ferry";
  }

  function randomKey() {
    var bytes = new Uint8Array(32);
    crypto.getRandomValues(bytes);
    return Array.prototype.map.call(bytes, function (b) { return ("0" + b.toString(16)).slice(-2); }).join("");
  }

  // ---- GitHub --------------------------------------------------------------------
  function github(token, method, path, body, allow404) {
    return fetch(API + path, {
      method: method,
      headers: {
        "Accept": "application/vnd.github+json",
        "Authorization": "Bearer " + token,
        "X-GitHub-Api-Version": "2022-11-28",
        "Content-Type": "application/json",
      },
      body: body ? JSON.stringify(body) : undefined,
      cache: "no-store",
    }).then(function (response) {
      if (response.status === 204) return null;
      if (response.status === 404 && allow404) return null;
      return response.json().catch(function () { return null; }).then(function (data) {
        if (!response.ok) {
          var hint = response.status === 401 ? " Check the token."
            : response.status === 403 || response.status === 404
              ? " Check the token is for this repository, with Actions and Secrets set to Read and write and Pages to Read."
              : "";
          throw new Error((data && data.message ? data.message : "GitHub error " + response.status) + "." + hint);
        }
        return data;
      });
    });
  }

  function linkedError(message, url, label) {
    var error = new Error(message);
    error.url = url;
    error.label = label;
    return error;
  }

  // ---- Progress ------------------------------------------------------------------
  function step(text, kind) {
    var li = document.createElement("li");
    li.textContent = text;
    if (kind) li.className = kind;
    $("progress").appendChild(li);
    $("progress").hidden = false;
    return li;
  }

  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  /// Waits for the run's deploy job. Private runs keep going afterwards (they wait to
  /// take the app down again), so the run itself isn't finished at that point.
  function waitForDeploy(token, repo, since, line) {
    var deadline = Date.now() + 30 * 60 * 1000;
    var started = Date.now();
    var run = null;
    function poll() {
      if (Date.now() > deadline) throw new Error("The build is taking unusually long. Check the Actions tab of your copy.");
      var findRun = run ? Promise.resolve(run)
        : github(token, "GET", "/repos/" + repo + "/actions/workflows/" + WORKFLOW + "/runs?event=workflow_dispatch&per_page=5")
          .then(function (data) {
            return (data.workflow_runs || []).filter(function (r) { return new Date(r.created_at).getTime() >= since - 60000; })[0] || null;
          });
      return findRun.then(function (found) {
        run = found;
        if (!run) { line.textContent = "Starting the build…"; return sleep(5000).then(poll); }
        line.dataset.url = run.html_url;
        return github(token, "GET", "/repos/" + repo + "/actions/runs/" + run.id + "/jobs").then(function (data) {
          var jobs = data.jobs || [];
          var failed = jobs.filter(function (j) { return ["failure", "cancelled", "timed_out"].indexOf(j.conclusion) >= 0; })[0];
          if (failed) {
            throw linkedError("The " + failed.name + " step failed. Open the log to see why. A wrong .p12 password is the most common cause.", run.html_url, "Open the build log");
          }
          var deploy = jobs.filter(function (j) { return j.name === "deploy"; })[0];
          if (deploy && deploy.conclusion === "success") return run;
          var build = jobs.filter(function (j) { return j.name === "build"; })[0];
          if (build && build.conclusion === "skipped") {
            throw linkedError("GitHub Pages isn't turned on in your copy.", "https://github.com/" + repo + "/settings/pages", "Open Pages settings");
          }
          var minutes = Math.round((Date.now() - started) / 60000);
          line.textContent = (deploy && deploy.status !== "queued" ? "Publishing…" : "Building and signing on GitHub…") +
            " (" + minutes + " min, usually 5–10)";
          return sleep(10000).then(poll);
        });
      });
    }
    return poll();
  }

  function waitForSite(infoURL, runId, line) {
    var deadline = Date.now() + 10 * 60 * 1000;
    function poll() {
      if (Date.now() > deadline) throw new Error("Your page hasn't updated yet. Try the link in a few minutes.");
      return fetch(infoURL + "?t=" + Date.now(), { cache: "no-store" })
        .then(function (r) { return r.ok ? r.json() : null; })
        .catch(function () { return null; })
        .then(function (info) {
          if (info && info.signed && String(info.runId) === String(runId)) return info;
          line.textContent = "Waiting for your page to update…";
          return sleep(5000).then(poll);
        });
    }
    return poll();
  }

  function showResult(link, expiresAt) {
    $("result").hidden = false;
    $("result-link").value = link;
    $("result-open").href = link;
    $("result-expiry").textContent = expiresAt
      ? "Works until " + new Date(expiresAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) +
        ". Open it in Safari on your iPhone. Only people with this link can see it."
      : "Open it in Safari on your iPhone.";
  }

  // ---- Main action -----------------------------------------------------------------
  function start(event) {
    event.preventDefault();
    var button = $("sign-button");
    var token = $("token").value.trim();
    var repo = $("repo").value.trim().replace(/^https?:\/\/github\.com\//, "").replace(/(\.git)?\/?$/, "");
    var password = $("p12-password").value;
    var bundleID = $("bundle-id").value.trim();
    var keep = $("keep").value;
    var isPrivate = keep !== "public";
    var forget = $("forget").checked;
    $("progress").innerHTML = "";
    $("result").hidden = true;

    if (!navigator.onLine) { step("You're offline. Connect to the internet first.", "warn"); return; }
    if (!/^[\w.-]+\/[\w.-]+$/.test(repo)) { step("Enter your copy as owner/name, for example your-name/Ferry.", "warn"); return; }
    if (!token) { step("Paste your GitHub token.", "warn"); return; }
    if (!profileInfo) { step("Choose your provisioning profile.", "warn"); return; }
    if (profileInfo.kind === "App Store" || (profileInfo.expires && profileInfo.expires <= new Date())) {
      step("That profile can't be used (see above).", "warn"); return;
    }
    if (bundleID && !profileInfo.covers(bundleID)) {
      step("The profile's App ID (" + profileInfo.pattern + ") doesn't cover " + bundleID + ".", "warn"); return;
    }

    button.disabled = true;
    var current = step("Reading your files…");
    var p12Base64, profileBase64, since, siteBase, run;
    var installKey = isPrivate ? randomKey() : "";

    Promise.all([readFile($("p12")), readFile($("profile"))])
      .then(function (files) {
        p12Base64 = SealedBox.toBase64(files[0]);
        profileBase64 = SealedBox.toBase64(files[1]);
        current.className = "done";
        current = step("Checking your copy of Ferry…");
        return Promise.all([
          github(token, "GET", "/repos/" + repo),
          github(token, "GET", "/repos/" + repo + "/pages", null, true),
          github(token, "GET", "/repos/" + repo + "/actions/workflows/" + WORKFLOW, null, true),
        ]);
      })
      .then(function (results) {
        var repository = results[0], pages = results[1], workflow = results[2];
        if (!workflow) {
          throw linkedError("This repository doesn't have Ferry's Install page workflow. Make your own copy of Ferry first.",
                            $("fork-link").href, "Copy Ferry");
        }
        if (workflow.state && workflow.state !== "active") {
          throw linkedError("Workflows are turned off in your copy. Open its Actions tab and turn them on.",
                            "https://github.com/" + repo + "/actions", "Open Actions");
        }
        if (!pages || pages.build_type !== "workflow") {
          throw linkedError("Turn on GitHub Pages in your copy (Source: GitHub Actions), then try again.",
                            "https://github.com/" + repo + "/settings/pages", "Open Pages settings");
        }
        siteBase = (pages.html_url || "").replace(/\/?$/, "/");
        rememberRepository(repo);
        current.className = "done";
        current = step("Encrypting and saving to your copy's secrets…");
        return github(token, "GET", "/repos/" + repo + "/actions/secrets/public-key").then(function (key) {
          return { key: key, defaultBranch: repository.default_branch };
        });
      })
      .then(function (ctx) {
        var secrets = {
          SIGNING_CERTIFICATE_P12: p12Base64,
          SIGNING_CERTIFICATE_PASSWORD: password,
          PROVISIONING_PROFILE: profileBase64,
        };
        if (isPrivate) secrets.INSTALL_KEY = installKey;
        var writes = Object.keys(secrets).map(function (name) {
          return github(token, "PUT", "/repos/" + repo + "/actions/secrets/" + name, {
            encrypted_value: SealedBox.encryptSecret(secrets[name], ctx.key.key),
            key_id: ctx.key.key_id,
          });
        });
        if (!isPrivate) writes.push(github(token, "DELETE", "/repos/" + repo + "/actions/secrets/INSTALL_KEY", null, true));
        return Promise.all(writes).then(function () { return ctx.defaultBranch; });
      })
      .then(function (defaultBranch) {
        p12Base64 = profileBase64 = password = null;
        $("p12-password").value = "";
        current.className = "done";
        current = step("Starting the build…");
        since = Date.now();
        var inputs = { keep_minutes: isPrivate ? keep : "0" };
        if (bundleID) inputs.bundle_id = bundleID;
        return github(token, "POST", "/repos/" + repo + "/actions/workflows/" + WORKFLOW + "/dispatches", {
          ref: defaultBranch,
          inputs: inputs,
        });
      })
      .then(function () { return waitForDeploy(token, repo, since, current); })
      .then(function (finished) {
        run = finished;
        current.className = "done";
        current.textContent = "Built and signed.";
        if (!forget) return null;
        current = step("Deleting your certificate and profile from GitHub…");
        return Promise.all(SECRET_NAMES.map(function (name) {
          return github(token, "DELETE", "/repos/" + repo + "/actions/secrets/" + name, null, true);
        })).then(function () { current.className = "done"; current.textContent = "Deleted from GitHub."; });
      })
      .then(function () {
        current = step("Waiting for your page to update…");
        var infoURL = siteBase + (isPrivate ? "i/" + installKey + "/" : "") + "info.json";
        return waitForSite(infoURL, run.id, current);
      })
      .then(function (info) {
        current.className = "done";
        current.textContent = "Published.";
        $("token").value = "";
        var link = siteBase + (isPrivate ? "#k=" + installKey : "");
        showResult(link, info.expiresAt);
        step("Ready.", "done");
        if (sameSite(siteBase)) {
          setTimeout(function () { location.href = link; if (!isPrivate) location.reload(); }, 1500);
        }
      })
      .catch(function (error) {
        current.className = "warn";
        current.textContent = error.message;
        var url = error.url || current.dataset.url;
        if (url) {
          var link = document.createElement("a");
          link.href = url;
          link.textContent = " " + (error.label || "Open the build log");
          link.target = "_blank";
          link.rel = "noopener";
          current.appendChild(link);
        }
      })
      .then(function () { button.disabled = false; });
  }

  // ---- Wire up ----------------------------------------------------------------------
  var home = siteRepository();
  $("repo").value = storedRepository() || home;
  $("fork-link").href = home ? "https://github.com/" + home + "/fork" : "https://github.com/";
  $("token-link").href = "https://github.com/settings/personal-access-tokens/new";
  $("profile").addEventListener("change", function () {
    profileInfo = null;
    readFile($("profile"))
      .then(function (bytes) { profileInfo = parseProfile(bytes); showProfile(profileInfo); })
      .catch(function (error) { showProfile(null, error.message); });
  });
  $("sign-form").addEventListener("submit", start);
  $("result-copy").addEventListener("click", function () {
    var text = $("result-link").value;
    (navigator.clipboard ? navigator.clipboard.writeText(text) : Promise.reject())
      .then(function () { $("result-copy").textContent = "Copied"; })
      .catch(function () { $("result-link").select(); });
  });
})();
