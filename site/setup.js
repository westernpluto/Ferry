// "Sign with your certificate": reads your .p12 and profile in the browser, encrypts
// them for GitHub (sealed boxes), saves them as repository secrets, starts the
// Install page workflow and follows it until the signed build is live.
// Nothing is stored in the browser and nothing is sent anywhere except api.github.com.
(function () {
  "use strict";

  var API = "https://api.github.com";
  var WORKFLOW = "pages.yml";
  var $ = function (id) { return document.getElementById(id); };

  var profileInfo = null;

  // ---- Repository from the Pages address -------------------------------------
  function detectRepository() {
    var host = location.hostname;
    if (!/\.github\.io$/i.test(host)) return "";
    var owner = host.split(".")[0];
    var first = location.pathname.split("/").filter(Boolean)[0];
    return owner + "/" + (first || owner + ".github.io");
  }

  // ---- Files ---------------------------------------------------------------------
  function readFile(input) {
    return new Promise(function (resolve, reject) {
      var file = input.files && input.files[0];
      if (!file) return reject(new Error("Choose a file first."));
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

  // ---- GitHub --------------------------------------------------------------------
  function github(token, method, path, body) {
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
      return response.json().catch(function () { return null; }).then(function (data) {
        if (!response.ok) {
          var hint = response.status === 401 ? " Check the token."
            : response.status === 403 || response.status === 404 ? " Check the token has access to this repository with Actions and Secrets set to Read and write."
            : "";
          throw new Error((data && data.message ? data.message : "GitHub error " + response.status) + "." + hint);
        }
        return data;
      });
    });
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

  function waitForRun(token, repo, since, line) {
    var deadline = Date.now() + 30 * 60 * 1000;
    var started = Date.now();
    function poll() {
      if (Date.now() > deadline) throw new Error("The build is taking unusually long. Check the Actions tab.");
      return github(token, "GET", "/repos/" + repo + "/actions/workflows/" + WORKFLOW + "/runs?event=workflow_dispatch&per_page=5")
        .then(function (data) {
          var run = (data.workflow_runs || []).filter(function (r) { return new Date(r.created_at).getTime() >= since - 60000; })[0];
          var minutes = Math.round((Date.now() - started) / 60000);
          if (!run) {
            line.textContent = "Starting the build…";
          } else if (run.status !== "completed") {
            line.textContent = "Building and signing on GitHub… (" + minutes + " min, usually 5–10)";
            line.dataset.url = run.html_url;
          } else if (run.conclusion === "success") {
            return run;
          } else {
            var error = new Error("The build failed. Open its log to see why. A wrong .p12 password is the most common cause.");
            error.url = run.html_url;
            throw error;
          }
          return sleep(10000).then(poll);
        });
    }
    return poll();
  }

  function waitForPage(commit, line) {
    var deadline = Date.now() + 10 * 60 * 1000;
    function poll() {
      if (Date.now() > deadline) throw new Error("The page hasn't updated yet. Reload in a few minutes.");
      return fetch("info.json?t=" + Date.now(), { cache: "no-store" })
        .then(function (r) { return r.ok ? r.json() : null; })
        .catch(function () { return null; })
        .then(function (info) {
          if (info && info.signed && info.commit && commit.indexOf(info.commit) === 0) return info;
          line.textContent = "Publishing the page…";
          return sleep(5000).then(poll);
        });
    }
    return poll();
  }

  // ---- Main action -----------------------------------------------------------------
  function start(event) {
    event.preventDefault();
    var button = $("sign-button");
    var token = $("token").value.trim();
    var repo = $("repo").value.trim().replace(/^https?:\/\/github\.com\//, "").replace(/\/$/, "");
    var password = $("p12-password").value;
    var bundleID = $("bundle-id").value.trim();
    $("progress").innerHTML = "";

    if (!navigator.onLine) { step("You're offline. Connect to the internet first.", "warn"); return; }
    if (!/^[\w.-]+\/[\w.-]+$/.test(repo)) { step("Enter the repository as owner/name.", "warn"); return; }
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
    var p12Base64, profileBase64, since;

    Promise.all([readFile($("p12")), readFile($("profile"))])
      .then(function (files) {
        p12Base64 = SealedBox.toBase64(files[0]);
        profileBase64 = SealedBox.toBase64(files[1]);
        current.className = "done";
        current = step("Encrypting and saving to your repository's secrets…");
        return Promise.all([
          github(token, "GET", "/repos/" + repo),
          github(token, "GET", "/repos/" + repo + "/actions/secrets/public-key"),
        ]);
      })
      .then(function (results) {
        var defaultBranch = results[0].default_branch;
        var key = results[1];
        var secrets = {
          SIGNING_CERTIFICATE_P12: p12Base64,
          SIGNING_CERTIFICATE_PASSWORD: password,
          PROVISIONING_PROFILE: profileBase64,
        };
        return Promise.all(Object.keys(secrets).map(function (name) {
          return github(token, "PUT", "/repos/" + repo + "/actions/secrets/" + name, {
            encrypted_value: SealedBox.encryptSecret(secrets[name], key.key),
            key_id: key.key_id,
          });
        })).then(function () { return defaultBranch; });
      })
      .then(function (defaultBranch) {
        p12Base64 = profileBase64 = password = null;
        $("p12-password").value = "";
        current.className = "done";
        current = step("Starting the build…");
        since = Date.now();
        var inputs = bundleID ? { bundle_id: bundleID } : {};
        return github(token, "POST", "/repos/" + repo + "/actions/workflows/" + WORKFLOW + "/dispatches", {
          ref: defaultBranch,
          inputs: inputs,
        });
      })
      .then(function () { return waitForRun(token, repo, since, current); })
      .then(function (run) {
        current.className = "done";
        current.textContent = "Built and signed.";
        current = step("Publishing the page…");
        return waitForPage(run.head_sha, current);
      })
      .then(function () {
        current.className = "done";
        current.textContent = "Published.";
        step("Ready. Reloading…", "done");
        $("token").value = "";
        setTimeout(function () { location.reload(); }, 1200);
      })
      .catch(function (error) {
        current.className = "warn";
        current.textContent = error.message;
        if (error.url || current.dataset.url) {
          var link = document.createElement("a");
          link.href = error.url || current.dataset.url;
          link.textContent = " Open the build log";
          link.target = "_blank";
          link.rel = "noopener";
          current.appendChild(link);
        }
      })
      .then(function () { button.disabled = false; });
  }

  // ---- Wire up ----------------------------------------------------------------------
  $("repo").value = detectRepository();
  $("profile").addEventListener("change", function () {
    profileInfo = null;
    readFile($("profile"))
      .then(function (bytes) { profileInfo = parseProfile(bytes); showProfile(profileInfo); })
      .catch(function (error) { showProfile(null, error.message); });
  });
  $("sign-form").addEventListener("submit", start);
  var tokenLink = $("token-link");
  if (tokenLink) {
    tokenLink.href = "https://github.com/settings/personal-access-tokens/new";
  }
})();
