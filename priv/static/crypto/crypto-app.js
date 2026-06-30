// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Impulsa SLU

// Burnerpad page driver — vanilla, zero deps. Uses the SRI-pinned BurnerpadCrypto bundle for all crypto.
// Loaded as an external script so the pages enforce a strict `script-src 'self'` with NO inline scripts.
// This client is passphrase-only (suite 0x02): every secret is a KEY-LESS link plus a generated 7+ word
// phrase that never leaves the browser, shared out of band. Two pages: create (#bp-create) and reveal
// (#bp-psk-reveal). A reveal URL that carries a #fragment is a link-mode (0x01) link this client refuses.
(function () {
  "use strict";

  // ───────────────────────── pure core (DOM-free, unit-tested under Node) ─────────────────────────
  // These touch no DOM/network — the security-relevant string/parse logic, extracted so it can be unit
  // tested in isolation (test/crypto/core_test.mjs). The browser wires them to the DOM below; Node
  // `require()`s this file, gets `Core`, and never runs the browser code (the guard returns first).
  var Core = {
    // DISPLAY only: drop the scheme + leading www. so a share link reads cleanly (burnerpad.com/s/…). The
    // FULL url is what is actually copied/opened — this is presentation, never what authorizes a request.
    displayUrl: function (u) { return String(u).replace(/^https?:\/\//i, "").replace(/^www\./i, ""); },
    // Canonicalize a passphrase word to the form the key was derived from: trimmed + lowercased.
    canonWord: function (w) { return String(w).trim().toLowerCase(); },
    // Parse a pasted phrase into canonical word tokens, CAPPED at `max` so a runaway/malicious paste (e.g.
    // the whole 1296-word list) can't create thousands of chips and freeze the tab.
    parsePaste: function (text, max) {
      var toks = String(text).trim().split(/\s+/).filter(Boolean).map(Core.canonWord);
      return max && toks.length > max ? toks.slice(0, max) : toks;
    },
    // Create-page strength state from the word count `n` and how many random-core words `gen` remain.
    // < min words → "bad" (add more); >= min generated present → "ok" (very strong / mixed); otherwise the
    // random core dropped below the floor → "weak" + the "your own words are weaker" warning.
    strength: function (n, gen, min) {
      if (n < min) return { label: n + "/" + min + " words — add " + (min - n) + " more", cls: "strength bad", warn: false };
      if (gen >= min) return { label: "✓ " + n + " words · " + (n > gen ? "mixed" : "very strong"), cls: "strength ok", warn: false };
      return { label: n + " words · weaker", cls: "strength weak", warn: true };
    }
  };

  // Node (unit tests): export the pure core and STOP — there is no DOM/window here.
  if (typeof module !== "undefined" && module.exports) { module.exports = Core; return; }

  // ───────────────────────── browser: wire the DOM (uses Core for the pure bits) ─────────────────────────
  var C = window.BurnerpadCrypto;
  var enc = new TextEncoder();
  var dec = new TextDecoder();

  function $(id) { return document.getElementById(id); }
  function show(el) { if (el) el.hidden = false; }
  function hide(el) { if (el) el.hidden = true; }

  // Passphrase words: drawn uniformly (rejection-sampled — no modulo bias) from the EFF Short Wordlist #2
  // (1296 distinct words; edit-distance >=3, unique 3-char prefixes — for the spoken channel). A generated
  // 7-word phrase is ~72 bits, well beyond what PBKDF2-HMAC-SHA256 (600k) needs to make an offline guess of
  // the stored 0x02 blob infeasible. The same list backs the autocomplete on create (hand-pick) and reveal.
  // Wordlist (c) Electronic Frontier Foundation, CC BY 3.0 (https://www.eff.org/dice) — embedded data only.
  var WORDS = ("aardvark abandoned abbreviate abdomen abhorrence abiding abnormal abrasion absorbing abundant abyss academy accountant acetone achiness acid acoustics acquire acrobat actress acuteness aerosol aesthetic affidavit afloat afraid aftershave again agency aggressor aghast agitate agnostic agonizing agreeing aidless aimlessly ajar alarmclock albatross alchemy alfalfa algae aliens alkaline almanac alongside alphabet already also altitude aluminum always amazingly ambulance amendment amiable ammunition amnesty amoeba amplifier amuser anagram anchor android anesthesia angelfish animal anklet announcer anonymous answer antelope anxiety anyplace aorta apartment apnea apostrophe apple apricot aquamarine arachnid arbitrate ardently arena argument aristocrat armchair aromatic arrowhead arsonist artichoke asbestos ascend aseptic ashamed asinine asleep asocial asparagus astronaut asymmetric atlas atmosphere atom atrocious attic atypical auctioneer auditorium augmented auspicious automobile auxiliary avalanche avenue aviator avocado awareness awhile awkward awning awoke axially azalea babbling backpack badass bagpipe bakery balancing bamboo banana barracuda basket bathrobe bazooka blade blender blimp blouse blurred boatyard bobcat body bogusness bohemian boiler bonnet boots borough bossiness bottle bouquet boxlike breath briefcase broom brushes bubblegum buckle buddhist buffalo bullfrog bunny busboy buzzard cabin cactus cadillac cafeteria cage cahoots cajoling cakewalk calculator camera canister capsule carrot cashew cathedral caucasian caviar ceasefire cedar celery cement census ceramics cesspool chalkboard cheesecake chimney chlorine chopsticks chrome chute cilantro cinnamon circle cityscape civilian clay clergyman clipboard clock clubhouse coathanger cobweb coconut codeword coexistent coffeecake cognitive cohabitate collarbone computer confetti copier cornea cosmetics cotton couch coverless coyote coziness crawfish crewmember crib croissant crumble crystal cubical cucumber cuddly cufflink cuisine culprit cup curry cushion cuticle cybernetic cyclist cylinder cymbal cynicism cypress cytoplasm dachshund daffodil dagger dairy dalmatian dandelion dartboard dastardly datebook daughter dawn daytime dazzler dealer debris decal dedicate deepness defrost degree dehydrator deliverer democrat dentist deodorant depot deranged desktop detergent device dexterity diamond dibs dictionary diffuser digit dilated dimple dinnerware dioxide diploma directory dishcloth ditto dividers dizziness doctor dodge doll dominoes donut doorstep dorsal double downstairs dozed drainpipe dresser driftwood droppings drum dryer dubiously duckling duffel dugout dumpster duplex durable dustpan dutiful duvet dwarfism dwelling dwindling dynamite dyslexia eagerness earlobe easel eavesdrop ebook eccentric echoless eclipse ecosystem ecstasy edged editor educator eelworm eerie effects eggnog egomaniac ejection elastic elbow elderly elephant elfishly eliminator elk elliptical elongated elsewhere elusive elves emancipate embroidery emcee emerald emission emoticon emperor emulate enactment enchilada endorphin energy enforcer engine enhance enigmatic enjoyably enlarged enormous enquirer enrollment ensemble entryway enunciate envoy enzyme epidemic equipment erasable ergonomic erratic eruption escalator eskimo esophagus espresso essay estrogen etching eternal ethics etiquette eucalyptus eulogy euphemism euthanize evacuation evergreen evidence evolution exam excerpt exerciser exfoliate exhale exist exorcist explode exquisite exterior exuberant fabric factory faded failsafe falcon family fanfare fasten faucet favorite feasibly february federal feedback feigned feline femur fence ferret festival fettuccine feudalist feverish fiberglass fictitious fiddle figurine fillet finalist fiscally fixture flashlight fleshiness flight florist flypaper foamless focus foggy folksong fondue footpath fossil fountain fox fragment freeway fridge frosting fruit fryingpan gadget gainfully gallstone gamekeeper gangway garlic gaslight gathering gauntlet gearbox gecko gem generator geographer gerbil gesture getaway geyser ghoulishly gibberish giddiness giftshop gigabyte gimmick giraffe giveaway gizmo glasses gleeful glisten glove glucose glycerin gnarly gnomish goatskin goggles goldfish gong gooey gorgeous gosling gothic gourmet governor grape greyhound grill groundhog grumbling guacamole guerrilla guitar gullible gumdrop gurgling gusto gutless gymnast gynecology gyration habitat hacking haggard haiku halogen hamburger handgun happiness hardhat hastily hatchling haughty hazelnut headband hedgehog hefty heinously helmet hemoglobin henceforth herbs hesitation hexagon hubcap huddling huff hugeness hullabaloo human hunter hurricane hushing hyacinth hybrid hydrant hygienist hypnotist ibuprofen icepack icing iconic identical idiocy idly igloo ignition iguana illuminate imaging imbecile imitator immigrant imprint iodine ionosphere ipad iphone iridescent irksome iron irrigation island isotope issueless italicize itemizer itinerary itunes ivory jabbering jackrabbit jaguar jailhouse jalapeno jamboree janitor jarring jasmine jaundice jawbreaker jaywalker jazz jealous jeep jelly jeopardize jersey jetski jezebel jiffy jigsaw jingling jobholder jockstrap jogging john joinable jokingly journal jovial joystick jubilant judiciary juggle juice jujitsu jukebox jumpiness junkyard juror justifying juvenile kabob kamikaze kangaroo karate kayak keepsake kennel kerosene ketchup khaki kickstand kilogram kimono kingdom kiosk kissing kite kleenex knapsack kneecap knickers koala krypton laboratory ladder lakefront lantern laptop laryngitis lasagna latch laundry lavender laxative lazybones lecturer leftover leggings leisure lemon length leopard leprechaun lettuce leukemia levers lewdness liability library licorice lifeboat lightbulb likewise lilac limousine lint lioness lipstick liquid listless litter liverwurst lizard llama luau lubricant lucidity ludicrous luggage lukewarm lullaby lumberjack lunchbox luridness luscious luxurious lyrics macaroni maestro magazine mahogany maimed majority makeover malformed mammal mango mapmaker marbles massager matchstick maverick maximum mayonnaise moaning mobilize moccasin modify moisture molecule momentum monastery moonshine mortuary mosquito motorcycle mousetrap movie mower mozzarella muckiness mudflow mugshot mule mummy mundane muppet mural mustard mutation myriad myspace myth nail namesake nanosecond napkin narrator nastiness natives nautically navigate nearest nebula nectar nefarious negotiator neither nemesis neoliberal nephew nervously nest netting neuron nevermore nextdoor nicotine niece nimbleness nintendo nirvana nuclear nugget nuisance nullify numbing nuptials nursery nutcracker nylon oasis oat obediently obituary object obliterate obnoxious observer obtain obvious occupation oceanic octopus ocular office oftentimes oiliness ointment older olympics omissible omnivorous oncoming onion onlooker onstage onward onyx oomph opaquely opera opium opossum opponent optical opulently oscillator osmosis ostrich otherwise ought outhouse ovation oven owlish oxford oxidize oxygen oyster ozone pacemaker padlock pageant pajamas palm pamphlet pantyhose paprika parakeet passport patio pauper pavement payphone pebble peculiarly pedometer pegboard pelican penguin peony pepperoni peroxide pesticide petroleum pewter pharmacy pheasant phonebook phrasing physician plank pledge plotted plug plywood pneumonia podiatrist poetic pogo poison poking policeman poncho popcorn porcupine postcard poultry powerboat prairie pretzel princess propeller prune pry pseudo psychopath publisher pucker pueblo pulley pumpkin punchbowl puppy purse pushup putt puzzle pyramid python quarters quesadilla quilt quote racoon radish ragweed railroad rampantly rancidity rarity raspberry ravishing rearrange rebuilt receipt reentry refinery register rehydrate reimburse rejoicing rekindle relic remote renovator reopen reporter request rerun reservoir retriever reunion revolver rewrite rhapsody rhetoric rhino rhubarb rhyme ribbon riches ridden rigidness rimmed riptide riskily ritzy riverboat roamer robe rocket romancer ropelike rotisserie roundtable royal rubber rudderless rugby ruined rulebook rummage running rupture rustproof sabotage sacrifice saddlebag saffron sainthood saltshaker samurai sandworm sapphire sardine sassy satchel sauna savage saxophone scarf scenario schoolbook scientist scooter scrapbook sculpture scythe secretary sedative segregator seismology selected semicolon senator septum sequence serpent sesame settler severely shack shelf shirt shovel shrimp shuttle shyness siamese sibling siesta silicon simmering singles sisterhood sitcom sixfold sizable skateboard skeleton skies skulk skylight slapping sled slingshot sloth slumbering smartphone smelliness smitten smokestack smudge snapshot sneezing sniff snowsuit snugness speakers sphinx spider splashing sponge sprout spur spyglass squirrel statue steamboat stingray stopwatch strawberry student stylus suave subway suction suds suffocate sugar suitcase sulphur superstore surfer sushi swan sweatshirt swimwear sword sycamore syllable symphony synagogue syringes systemize tablespoon taco tadpole taekwondo tagalong takeout tallness tamale tanned tapestry tarantula tastebud tattoo tavern thaw theater thimble thorn throat thumb thwarting tiara tidbit tiebreaker tiger timid tinsel tiptoeing tirade tissue tractor tree tripod trousers trucks tryout tubeless tuesday tugboat tulip tumbleweed tupperware turtle tusk tutorial tuxedo tweezers twins tyrannical ultrasound umbrella umpire unarmored unbuttoned uncle underwear unevenness unflavored ungloved unhinge unicycle unjustly unknown unlocking unmarked unnoticed unopened unpaved unquenched unroll unscrewing untied unusual unveiled unwrinkled unyielding unzip upbeat upcountry update upfront upgrade upholstery upkeep upload uppercut upright upstairs uptown upwind uranium urban urchin urethane urgent urologist username usher utensil utility utmost utopia utterance vacuum vagrancy valuables vanquished vaporizer varied vaseline vegetable vehicle velcro vendor vertebrae vestibule veteran vexingly vicinity videogame viewfinder vigilante village vinegar violin viperfish virus visor vitamins vivacious vixen vocalist vogue voicemail volleyball voucher voyage vulnerable waffle wagon wakeup walrus wanderer wasp water waving wheat whisper wholesaler wick widow wielder wifeless wikipedia wildcat windmill wipeout wired wishbone wizardry wobbliness wolverine womb woolworker workbasket wound wrangle wreckage wristwatch wrongdoing xerox xylophone yacht yahoo yard yearbook yesterday yiddish yield yo-yo yodel yogurt yuppie zealot zebra zeppelin zestfully zigzagged zillion zipping zirconium zodiac zombie zookeeper zucchini").split(" ");
  function randIndex(n) {
    var lim = Math.floor(65536 / n) * n, b = new Uint16Array(1);
    do { crypto.getRandomValues(b); } while (b[0] >= lim);
    return b[0] % n;
  }
  // A passphrase is N distinct words from WORDS joined by single spaces. Distinctness is enforced
  // everywhere — generate, reroll, and hand-pick — so every phrase is N>=7 distinct words, and the
  // canonical "lowercase words, single spaces" join matches what PBKDF2 derived the key from.
  function genDistinct(n) {
    var out = [];
    while (out.length < n) {
      var w = WORDS[randIndex(WORDS.length)];
      if (out.indexOf(w) === -1) out.push(w);
    }
    return out;
  }

  // Brief "Copied ✓" feedback on a button, then restore it. Saves/restores innerHTML (not textContent)
  // so a button that holds an icon + label keeps its icon after the flash. Re-entrancy-safe: a second
  // click within the window reuses the originally-captured markup (never the swapped "Copied ✓" state).
  function flash(btn) {
    if (btn._flashTimer) clearTimeout(btn._flashTimer);
    else btn._flashHtml = btn.innerHTML;
    btn.textContent = "Copied ✓";
    btn._flashTimer = setTimeout(function () { btn.innerHTML = btn._flashHtml; btn._flashTimer = null; }, 1500);
  }

  // A removable word chip: the word + an "×" that calls onRemove.
  function removableChip(word, onRemove) {
    var chip = document.createElement("span");
    chip.className = "chip";
    var label = document.createElement("span");
    label.textContent = word;
    chip.appendChild(label);
    var x = document.createElement("button");
    x.type = "button";
    x.className = "chip-x";
    x.textContent = "×";
    x.setAttribute("aria-label", "remove " + word);
    x.addEventListener("click", onRemove);
    chip.appendChild(x);
    return chip;
  }

  // Wire a text input + listbox into a LIST-LOCKED autocomplete over WORDS: prefix matches (excluding
  // already-chosen words), keyboard-navigable, committing only real list words. Hand-rolled (zero deps),
  // ARIA combobox semantics. The owner keeps the chosen-words array; we only call back into it.
  function wireAutocomplete(input, list, opts) {
    var items = [];   // the words currently suggested
    var active = -1;  // highlighted suggestion (-1 = none)
    var blurTimer = null;
    function clearBlur() { if (blurTimer) { clearTimeout(blurTimer); blurTimer = null; } }

    function close() {
      clearBlur();
      list.hidden = true;
      list.textContent = "";
      items = [];
      active = -1;
      input.setAttribute("aria-expanded", "false");
      input.removeAttribute("aria-activedescendant");
    }
    function highlight() {
      for (var i = 0; i < list.children.length; i++) {
        var on = i === active;
        list.children[i].classList.toggle("active", on);
        if (on) input.setAttribute("aria-activedescendant", list.children[i].id);
      }
    }
    function render() {
      clearBlur(); // a fresh keystroke cancels a pending blur-close, so a reopened list can't be eaten
      var pfx = input.value.trim().toLowerCase();
      items = [];
      if (pfx) {
        var chosen = opts.getChosen();
        for (var i = 0; i < WORDS.length && items.length < 8; i++) {
          if (WORDS[i].indexOf(pfx) === 0 && chosen.indexOf(WORDS[i]) === -1) items.push(WORDS[i]);
        }
      }
      list.textContent = "";
      if (!items.length) { close(); return; }
      items.forEach(function (w, idx) {
        var li = document.createElement("li");
        li.className = "suggest-item";
        li.setAttribute("role", "option");
        li.id = list.id + "-opt-" + idx;
        li.textContent = w;
        // mousedown (not click) so the pick fires before the input's blur closes the list
        li.addEventListener("mousedown", function (e) { e.preventDefault(); choose(idx); });
        list.appendChild(li);
      });
      active = 0;
      highlight();
      list.hidden = false;
      input.setAttribute("aria-expanded", "true");
    }
    function choose(idx) {
      var w = items[idx];
      if (!w) return;
      opts.onPick(w);
      input.value = "";
      close();
      input.focus();
    }

    input.addEventListener("input", render);
    input.addEventListener("keydown", function (e) {
      if (e.key === "ArrowDown") {
        if (items.length) { active = Math.min(active + 1, items.length - 1); highlight(); e.preventDefault(); }
      } else if (e.key === "ArrowUp") {
        if (items.length) { active = Math.max(active - 1, 0); highlight(); e.preventDefault(); }
      } else if (e.key === "Enter" || e.key === " ") {
        // Enter or Space commits the highlighted word — a word is a single token, so Space never types a literal space
        e.preventDefault();
        if (items.length && active >= 0) choose(active);
      } else if (e.key === "Tab" && !e.shiftKey && items.length && active >= 0) {
        // Tab also commits and keeps focus for the next word; with no suggestion open, Tab still moves on normally
        e.preventDefault();
        choose(active);
      } else if (e.key === "Escape") {
        if (!list.hidden) { close(); e.preventDefault(); }
      } else if (e.key === "Backspace" && !input.value) {
        if (opts.onBackspace) opts.onBackspace();
      }
    });
    input.addEventListener("blur", function () { clearBlur(); blurTimer = setTimeout(close, 120); });
  }

  // ───────────────────────── create page ─────────────────────────
  var form = $("bp-create");
  if (form) {
    var input = $("bp-input"), result = $("bp-result"), link = $("bp-link"), error = $("bp-error");
    var intro = $("bp-intro"); // hero + feature strip — create-only; hidden once a secret is created
    var createBtn = $("bp-create-btn");
    var createLabel = createBtn.querySelector(".btn-label"); // the submit button's text node (icon stays put)
    var createMeta = $("bp-create-meta");
    var copyBtn = $("bp-copy"), copyPhraseBtn = $("bp-copy-phrase");
    var burnBtn = $("bp-burn"), burned = $("bp-burned"), share = $("bp-share"), again = $("bp-again");
    var burnLabel = burnBtn && burnBtn.querySelector(".btn-label"); // keep the flame icon when relabeling
    function setBurnLabel(t) { if (burnLabel) burnLabel.textContent = t; else if (burnBtn) burnBtn.textContent = t; }
    var passChips = $("bp-pass-chips"), passOut = $("bp-pass-out");
    var passInput = $("bp-pass-input"), passSuggest = $("bp-pass-suggest"), passField = $("bp-pass-field");
    var warn = $("bp-pass-warn"), strengthEl = $("bp-pass-strength"), regenBtn = $("bp-pass-regen");

    var MIN = 7;
    var words = genDistinct(MIN); // 7 generated words, shown in the field on load
    var genWords = new Set(words); // the generated (uniformly-random) words still present — the entropy floor
    var submitting = false;       // true during the async encrypt+POST (so the "Creating…" guard isn't undone)
    var current = null;           // {id, mgmt} once created
    var phrase = "";              // the committed phrase string

    function removeWord(i) {
      genWords.delete(words[i]); // if a generated/random word goes, the entropy floor drops
      words.splice(i, 1);
      renderChips();
      passInput.focus();
    }

    function renderChips() {
      passChips.textContent = "";
      words.forEach(function (w, i) {
        passChips.appendChild(removableChip(w, function () { removeWord(i); }));
      });
      updateStrength();
    }

    function setCreateLabel(t) { if (createLabel) createLabel.textContent = t; else createBtn.textContent = t; }

    // The submit button is ALWAYS active (matching the design). Its label flips on whether a secret is
    // present: empty → "Add your secret to continue", filled → "Encrypt & create link". Clicking with no
    // secret nudges focus to the textarea; clicking with <7 words surfaces an error (see the submit handler).
    function refreshCreateBtn() {
      if (submitting) return; // don't clobber the in-flight "Creating…" label
      setCreateLabel(input.value.trim() ? "Encrypt & create link" : "Add your secret to continue");
    }

    // Live meta on the secret field: line count + UTF-8 size, flagged red past the blob limit. The server
    // caps the ENCRYPTED blob (max_blob = 65536); a suite-0x02 blob is the plaintext plus 45 bytes of
    // overhead (1 header + 16 salt + 12 iv + 16 GCM tag), so the plaintext budget is 65536 - 45.
    var MAX_PLAINTEXT = 65536 - 45;
    function updateMeta() {
      if (!createMeta) return;
      var v = input.value;
      if (!v) { hide(createMeta); return; }
      var bytes = enc.encode(v).length, lines = v.split("\n").length;
      var size = bytes < 1024 ? bytes + " B" : (bytes / 1024).toFixed(1) + " KB";
      createMeta.textContent = lines + (lines === 1 ? " line · " : " lines · ") + size +
        (bytes > MAX_PLAINTEXT ? " · over 64 KB limit" : "");
      createMeta.style.color = bytes > MAX_PLAINTEXT ? "var(--bad)" : (bytes > MAX_PLAINTEXT * 0.9 ? "var(--warn)" : "var(--muted)");
      show(createMeta);
    }

    input.addEventListener("input", function () { refreshCreateBtn(); updateMeta(); }); // re-check on each keystroke

    // Strength tracks the RANDOM core: while >=7 generated words remain the phrase is strong (adding your own
    // words on top only adds entropy — "mixed"). Removing random words below the floor is what weakens it.
    function updateStrength() {
      var s = Core.strength(words.length, genWords.size, MIN);
      strengthEl.textContent = s.label;
      strengthEl.className = s.cls;
      if (s.warn) show(warn); else hide(warn); // warn when the random core dropped below the floor
    }

    wireAutocomplete(passInput, passSuggest, {
      getChosen: function () { return words; },
      onPick: function (w) {
        if (words.indexOf(w) !== -1) return;
        words.push(w); // a typed word is custom — it is NOT part of the random core (genWords)
        renderChips();
      },
      onBackspace: function () { if (words.length) removeWord(words.length - 1); }
    });

    // Regenerate: a fresh uniformly-random set — back to the pristine generated state (warning resets).
    if (regenBtn) regenBtn.addEventListener("click", function () {
      words = genDistinct(MIN);
      genWords = new Set(words);
      passInput.value = "";
      renderChips(); // → updateStrength: back to green, warning hidden
      passInput.focus();
    });

    // Clicking anywhere in the field that isn't a control (a chip ×, the regenerate button) focuses the input.
    if (passField) passField.addEventListener("click", function (e) {
      if (!e.target.closest("button, input")) passInput.focus();
    });

    function renderResultChips(arr) {
      passOut.textContent = "";
      arr.forEach(function (w) {
        var s = document.createElement("span");
        s.className = "chip";
        s.textContent = w;
        passOut.appendChild(s);
      });
    }

    form.addEventListener("submit", async function (e) {
      e.preventDefault();
      if (submitting) return; // guard double-submit without ever disabling the (always-active) button
      hide(error); hide(burned);
      var text = input.value;
      if (!text.trim()) { input.focus(); return; } // no secret yet → nudge focus to the textarea, don't error
      if (words.length < MIN) {
        error.textContent = "Add at least " + MIN + " words to your passphrase.";
        show(error);
        return;
      }
      phrase = words.join(" "); // snapshot — the form stays live during the async encrypt+POST below
      submitting = true; // the guard at the top of submit blocks re-entry; the button itself stays active
      setCreateLabel("Creating…");
      try {
        var out = await C.encryptPsk(phrase, enc.encode(text)); // suite 0x02 — key-less link, no fragment
        var res = await fetch("/api/secrets", {
          method: "POST",
          headers: { "content-type": "application/json", "accept": "application/json" },
          body: JSON.stringify({ blob: C.b64url(out.blob) })
        });
        if (!res.ok) throw new Error("The server rejected the secret.");
        var data = await res.json();
        var url = C.buildUrl(location.origin, data.id, out.fragment); // out.fragment === "" → no key in URL
        current = { id: data.id, mgmt: data.mgmt_token, url: url };
        link.dataset.fullUrl = url; // the real URL to copy/open; the field shows it without scheme/www.
        link.value = Core.displayUrl(url);
        renderResultChips(phrase.split(" ")); // from the COMMITTED snapshot, never live `words` (a reroll
        hide(form); // mid-encrypt must not desync the shown phrase from the one the blob was sealed under)
        hide(intro); // drop the hero + feature strip — the success screen is just the header + hand-off
        show(result);
        link.focus(); // move focus into the result so AT announces it and the copy targets are in reach
      } catch (err) {
        error.textContent = err.message || "Something went wrong.";
        show(error);
        submitting = false;
        refreshCreateBtn(); // restore the label (the secret is still present → "Encrypt & create link")
      }
    });

    if (copyBtn) copyBtn.addEventListener("click", function () {
      link.select();
      // copy the FULL url (with scheme) even though the field shows it stripped — a scheme-less link isn't clickable
      if (navigator.clipboard) navigator.clipboard.writeText(link.dataset.fullUrl || link.value);
      flash(copyBtn);
    });

    // Copy passphrase: the words are offered for copying so they can go out on a SECOND channel (a separate
    // app, a text, a call). It is on the recipient to keep that channel apart from where the link was sent.
    // Copies the committed `phrase` snapshot — never live `words` (a mid-flight reroll must not desync it).
    if (copyPhraseBtn) copyPhraseBtn.addEventListener("click", function () {
      if (navigator.clipboard) navigator.clipboard.writeText(phrase);
      flash(copyPhraseBtn);
    });

    if (burnBtn) burnBtn.addEventListener("click", async function () {
      if (!current) return;
      burnBtn.disabled = true;
      setBurnLabel("Burning…");
      try {
        var res = await fetch("/s/" + current.id + "/burn", {
          method: "POST",
          headers: { "content-type": "application/json", "accept": "application/json" },
          body: JSON.stringify({ mgmt_token: current.mgmt })
        });
        // Don't claim "destroyed" on a server/proxy error that may have left the secret live. With the
        // correct id+token the route returns 200 (burned) or 403 (already revealed/expired = already gone);
        // only a 5xx is a genuine "we don't know" that must not be shown as burned.
        if (res.status >= 500) throw new Error("Could not burn the secret — try again.");
        hide(share); // burn lives inside #bp-share, so this removes the link/copy AND the burn button
        show(burned);
        again.focus(); // success path: focus the next action so AT announces the burned state
      } catch (_e) {
        burnBtn.disabled = false;
        setBurnLabel("Burn it now");
      }
    });

    // "Create another" — soft reset back to the form (no reload, no network). A fresh phrase is generated.
    if (again) again.addEventListener("click", function () {
      current = null;
      phrase = "";
      input.value = "";
      link.value = "";
      link.removeAttribute("data-full-url");
      passOut.textContent = "";
      words = genDistinct(MIN); // a fresh generated phrase for the next secret
      genWords = new Set(words);
      submitting = false;
      passInput.value = "";
      renderChips();
      updateMeta(); // the secret was cleared above — hide the line/size readout
      refreshCreateBtn(); // empty secret again → "Add your secret to continue"
      hide(result);
      hide(burned);
      hide(error);
      show(share);
      burnBtn.disabled = false;
      setBurnLabel("Burn it now");
      show(intro); // bring the hero + feature strip back for the fresh create form
      show(form);
      input.focus();
    });

    renderChips(); // initial paint of the generated chips
  }

  // ───────────────────────── reveal page ─────────────────────────
  var pskBtn = $("bp-psk-reveal");
  if (pskBtn) {
    var id = pskBtn.getAttribute("data-id");
    var revealed = $("bp-revealed"), secretOut = $("bp-secret"), copySecret = $("bp-copy-secret");
    var secretMeta = $("bp-secret-meta"), secretFade = $("bp-secret-fade");

    // Soft bottom fade on the code block while the secret overflows and isn't scrolled to the end.
    function updateSecretFade() {
      if (!secretFade || !secretOut) return;
      var over = secretOut.scrollHeight > secretOut.clientHeight + 2;
      var atBottom = secretOut.scrollTop + secretOut.clientHeight >= secretOut.scrollHeight - 2;
      secretFade.style.opacity = over && !atBottom ? "1" : "0";
    }
    if (secretOut) secretOut.addEventListener("scroll", updateSecretFade, { passive: true });

    if (copySecret) copySecret.addEventListener("click", function () {
      if (navigator.clipboard) navigator.clipboard.writeText(secretOut.textContent);
      flash(copySecret);
    });

    if (C.readFragment()) {
      // A #fragment is a link-mode (suite 0x01) key. This client mints and opens only key-less passphrase
      // secrets, so we refuse rather than guess — the fragment never reaches the server either way.
      show($("bp-unsupported"));
    } else {
      // ── passphrase mode (suite 0x02): no fragment; the recipient picks the words from the list ──
      var psk = $("bp-psk"), pskChips = $("bp-psk-chips"), pskField = $("bp-psk-field");
      var pskInput = $("bp-psk-input"), pskSuggest = $("bp-psk-suggest"), perr = $("bp-psk-error");
      var pskCount = $("bp-psk-count"), pskCountN = $("bp-psk-count-n");
      var pskIcon = pskBtn.querySelector("use"), pskLabel = pskBtn.querySelector(".btn-label");
      var MINREV = 7;
      var rwords = [];
      var heldBlob = null;   // the one network reveal (= the one burn); phrase retries are local
      var revealing = false; // guards the async reveal without disabling the (always-active) button

      function renderPskChips() {
        pskChips.textContent = "";
        rwords.forEach(function (w, i) {
          pskChips.appendChild(removableChip(w, function () { rwords.splice(i, 1); renderPskChips(); pskInput.focus(); }));
        });
        // count pill: "N / 7" (amber) until complete, then "✓ N" (green); the button label + icon flip too.
        var n = rwords.length, complete = n >= MINREV;
        if (pskCount) pskCount.classList.toggle("ok", complete);
        if (pskCountN) pskCountN.textContent = complete ? String(n) : n + " / " + MINREV;
        if (pskIcon) pskIcon.setAttribute("href", complete ? "#i-eye" : "#i-type");
        if (pskLabel) pskLabel.textContent = complete ? "Reveal & decrypt" : "Enter at least " + MINREV + " words";
      }

      // Append a word (from the autocomplete pick OR a paste). Canonicalizes to lowercase; list-locked typing
      // already guarantees real words, and a pasted phrase is the canonical lowercase form the key derived from.
      function addRev(w) { w = Core.canonWord(w); if (w && rwords.indexOf(w) === -1) rwords.push(w); }

      // Clicking anywhere in the field that isn't a control focuses the input (matches the create field).
      if (pskField) pskField.addEventListener("click", function (e) {
        if (!e.target.closest("button, input")) pskInput.focus();
      });

      wireAutocomplete(pskInput, pskSuggest, {
        getChosen: function () { return rwords; },
        onPick: function (w) { addRev(w); renderPskChips(); },
        onBackspace: function () { if (rwords.length) { rwords.pop(); renderPskChips(); } }
      });

      // Paste the whole phrase at once: Core.parsePaste splits on whitespace, canonicalizes every word, and
      // caps the count (MAX_PASTE) so a runaway/malicious paste can't flood the DOM. EVERY word becomes a
      // chip — including the last (no trailing space needed). A single-word paste falls through to typing.
      var MAX_PASTE = 64;
      pskInput.addEventListener("paste", function (e) {
        var cb = e.clipboardData; // standard paste DataTransfer (the only browsers without it lack WebCrypto)
        var tokens = Core.parsePaste((cb && cb.getData("text")) || "", MAX_PASTE);
        if (tokens.length < 2) return;
        e.preventDefault();
        tokens.forEach(addRev);
        pskInput.value = "";
        renderPskChips();
        pskInput.focus();
      });

      pskBtn.addEventListener("click", async function () {
        hide(perr);
        if (rwords.length < MINREV) { pskInput.focus(); return; } // always-active: nudge instead of blocking
        if (revealing) return; // guard the in-flight reveal (no second burn) without disabling the button
        revealing = true;
        try {
          if (!heldBlob) {
            var res = await fetch("/s/" + id + "/reveal", { method: "POST", headers: { "accept": "application/json" } });
            if (res.status === 410) throw new Error("This secret has already been read, or it expired.");
            if (!res.ok) throw new Error("Could not retrieve the secret.");
            heldBlob = C.unb64url((await res.json()).blob);
          }
          // List-locked chips are already canonical (lowercase words, single spaces) — exactly what the
          // key was derived from — so no transcription canonicalization is needed.
          var plain = await C.decryptPsk(heldBlob, rwords.join(" "));
          var text = dec.decode(plain);
          hide(psk);
          secretOut.textContent = text;
          if (secretMeta) { // "N lines · X KB" header, like the design
            var bytes = enc.encode(text).length, lines = text.split("\n").length;
            secretMeta.textContent = lines + (lines === 1 ? " line · " : " lines · ") +
              (bytes < 1024 ? bytes + " B" : (bytes / 1024).toFixed(1) + " KB");
          }
          show(revealed);
          requestAnimationFrame(updateSecretFade); // measure overflow once laid out
          if (copySecret) copySecret.focus(); // move focus into the result (AT announces; copy in reach)
        } catch (err) {
          // wrong phrase: keep heldBlob so the user can fix the words and retry locally (no second burn)
          perr.textContent = err.message === "auth_fail"
            ? "That phrase didn't open it — check the words and their order, then try again."
            : (err.message || "Could not decrypt the secret.");
          show(perr);
        } finally {
          revealing = false;
        }
      });

      show(psk);
      renderPskChips(); // initial paint: "0 / 7" pill + "Enter at least 7 words" button
    }
  }
})();
