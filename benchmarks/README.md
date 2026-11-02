# Benchmarks

How Purr compares with Wispr Flow and Superwhisper when all three hear the same audio, and how accurate Purr's engines are on public test sets.

Everything was measured between 31 October and 2 November 2026. The scripts, the reference text and every app's raw output are in [head-to-head/](head-to-head/), so you can check the scoring or run it yourself.

- [Purr vs Wispr Flow vs Superwhisper](#purr-vs-wispr-flow-vs-superwhisper)
- [Purr on public test sets](#purr-on-public-test-sets)
- [Numbers published by others](#numbers-published-by-others)
- [Run it yourself](#run-it-yourself)

## Purr vs Wispr Flow vs Superwhisper

The same clips were played into each app, one app at a time on the same Mac, using each app's own push-to-talk key. The text landed in a TextEdit document.

| App | Version and plan | Speech model | Where it runs |
|---|---|---|---|
| Purr | built from commit `cad9ffb` | Parakeet v2 for English, Whisper Large V3 Turbo for other languages | on the Mac |
| Wispr Flow | 1.6.1337, free plan | Wispr's own | Wispr's servers |
| Superwhisper | 3.1.0, free plan | Whisper Large V3 Turbo (local) | on the Mac |

Each app had the same 62 names and terms in its custom vocabulary.

### Where Purr wins

- **Fastest.** Text appears a median **0.22 s** after you let go of the key. Wispr Flow takes 0.63 s and Superwhisper 1.30 s, so Purr is about 3 times faster than Wispr Flow and 6 times faster than Superwhisper.
- **Fewest wrong swaps into custom words.** In 16 sentences that only *sound like* a custom word ("rock the baby in the cradle", with Gradle in the vocabulary), Purr swapped in a custom word **2** times, Wispr Flow 4 and Superwhisper 7.
- **Tied with Wispr Flow on hard audio, without the cloud.** Short answers, quiet speech, background noise and talkers, fast speech, a long pause and three accents: **4.0%** word errors for both, 10.0% for Superwhisper. They also tie on a 97-second dictation (**0.7%** each).
- **Long dictation.** A 5-minute monologue came back with **1.7%** word errors 5.7 s after release. Superwhisper had 5.0% after 20.7 s. Wispr Flow wasn't run on it, to stay inside its free plan's 2,000 words a week.
- **Voice Edit got 8 of 8 edits right**, from "Change Tuesday to Thursday" to "Translate this to Spanish". Wispr Flow's Command Mode (fn + Control) ignores the synthetic key presses the harness sends, so it couldn't be tested. Superwhisper can send selected text to an AI model through a custom mode, but we didn't set one up, so it wasn't tested either.
- **Ahead of Superwhisper on every measure**, including custom words (72.6% vs 51.6% spelled right) and other languages (7.1% vs 12.1% errors).
- **Free and open source**, with no account. Your audio never leaves the Mac.

### Where Purr is behind

- **Names and jargon.** Wispr Flow spelled **93.5%** of the custom words exactly right and Purr 72.6%. Purr missed rarer names such as Oluwaseun, Niamh, Saoirse and Wojciech.
- **Other languages.** Wispr Flow made 5.8% errors and Purr 7.1%. Wispr Flow was also faster here: 0.70 s against 1.08 s.
- **Everyday English.** Close, but Wispr Flow is ahead: 3.4% word errors against Purr's 3.8%.
- **One-word answers.** Purr typed nothing for a lone "Yes." (half a second of audio). The other two typed it.
- **Smart Typing** (Purr types while you talk) drops words. It made 8.0% errors on the same clips that scored 3.8% with normal dictation, and lost the last sentence of the 97-second clip.

### All results

The best result in each row is in bold.

| | Purr | Wispr Flow | Superwhisper |
|---|---|---|---|
| **Speed** (median time from key release to text) | | | |
| Everyday clips, 4.5-9 s | **0.22 s** | 0.63 s | 1.30 s |
| 97-second dictation | 2.1 s | **1.5 s** | 6.2 s |
| 5-minute dictation | **5.7 s** | not run | 20.7 s |
| 12 other languages | 1.08 s | **0.70 s** | 1.87 s |
| **Word error rate** (lower is better) | | | |
| Everyday speech, 25 clips | 3.8% | **3.4%** | 9.0% |
| Hard audio, 12 clips | **4.0%** | **4.0%** | 10.0% |
| Sentences with names and terms, 54 clips | 7.6% | **3.7%** | 14.3% |
| 97-second dictation | **0.7%** | **0.7%** | 2.6% |
| 5-minute dictation | **1.7%** | not run | 5.0% |
| 12 other languages, 24 clips | 7.1% | **5.8%** | 12.1% |
| **Custom vocabulary** | | | |
| Custom words spelled exactly right, of 62 | 72.6% | **93.5%** | 51.6% |
| Sound-alike sentences swapped into a custom word, of 16 | **2** | 4 | 7 |
| **Other** | | | |
| Key held in silence | **no text** | **no text** | **no text** |
| Voice Edit commands done right, of 8 | **8** | couldn't test | not tested |
| Works offline | **yes** | no | **yes** |

<details>
<summary><strong>Other languages, one by one</strong></summary>

Two sentences per language, read by macOS voices, with language detection on in every app. Word error rate, or character error rate for Japanese, Chinese and Korean. All three apps wrote all 24 in the right language.

| Language | Purr | Wispr Flow | Superwhisper |
|---|---|---|---|
| Spanish | **5%** | 10% | **5%** |
| French | **0%** | **0%** | **0%** |
| German | **0%** | **0%** | **0%** |
| Italian | **0%** | **0%** | 6% |
| Portuguese | **0%** | **0%** | **0%** |
| Dutch | **0%** | **0%** | 5% |
| Russian | **9%** | **9%** | **9%** |
| Hindi | 30% | **26%** | 67% |
| Japanese | 10% | **7%** | 14% |
| Chinese | 16% | **0%** | **0%** |
| Korean | **0%** | **0%** | 4% |
| Arabic | **0%** | 15% | 15% |

Purr wrote one of the two Chinese sentences in Traditional characters, which count as errors against the Simplified reference.

</details>

<details>
<summary><strong>Voice Edit, command by command</strong></summary>

The harness selected the text, held Control-Option-E and played the spoken command. Purr used Gemma 4 E2B. Each edit landed 0.6 to 1.3 s after the key was released.

| Selected text | Spoken command | Purr's result |
|---|---|---|
| The meeting is on Tuesday at 3 pm. | Change Tuesday to Thursday. | The meeting is on Thursday at 3 pm. |
| hey can you send me the report by friday thanks | Make this more formal. | Could you please send me the report by Friday? Thank you. |
| We shipped the update last week and users like it. | Translate this to Spanish. | Enviamos la actualización la semana pasada y a los usuarios les gusta. |
| The launch went well. Sales were strong. The team was happy. | Make it one sentence. | The launch went well, sales were strong, and the team was happy. |
| I think maybe we should probably consider moving the deadline to next month if that is possible. | Make it shorter. | Maybe we should move the deadline to next month if possible. |
| send the deck to anna and raj before the review | Capitalize the names. | send the deck to Anna and Raj before the review |
| Buy milk, eggs, bread and coffee. | Turn this into a bulleted list. | \* Buy milk<br>\* eggs<br>\* bread<br>\* coffee |
| The quick fix worked. | End it with an exclamation mark. | The quick fix worked! |

</details>

### How it was measured

**Clips** (all 16 kHz mono, built by [build.py](head-to-head/build.py) and [build_multi.py](head-to-head/build_multi.py)):

- **Everyday speech:** 25 sentences from LibriSpeech test-clean (13) and test-other (12), one per speaker, 4.5-9 s long.
- **Names and terms:** 54 sentences using 62 custom words (22 people's names and 40 product and tech names, listed in [words.txt](head-to-head/bench/words.txt)), plus 16 sound-alike sentences that don't contain them. All are read by the macOS voice Samantha.
- **Hard audio:** one-word and short answers, speech at -28 and -34 dB, three other talkers or noise at 5 dB SNR, fast speech, a 3-second pause mid-sentence, and Indian, Irish and Australian English voices. Twelve more clips cover silence, numbers, emails, spoken punctuation, fillers, self-correction, a command line, Hindi and Spanish. Those twelve were checked by eye but not scored, since each app formats them its own way.
- **Long dictation:** 97 s and 302 s of consecutive sentences from one LibriSpeech chapter.
- **Other languages:** 2 sentences in each of 12 languages, read by macOS voices.

**Playback and timing.** [run.zsh](head-to-head/run.zsh) presses the app's key and plays each clip in real time into BlackHole 2ch, a virtual audio device every app was set to use as its microphone. Then it releases the key. A poller reads the TextEdit document every 10 ms or so, starting before the key goes down. Speed is the time from key release to the first text.

**Scoring.** [score.py](head-to-head/score.py) computes word error rate after OpenAI Whisper's English text normalizer, so "3 pm" and "three p m" match and case and punctuation don't count. [score_multi.py](head-to-head/score_multi.py) uses Whisper's basic normalizer, with character error rate for Japanese, Chinese and Korean. A custom word counts as right only with exact spelling and case. A sound-alike swap is any custom word showing up in a sentence that doesn't contain it.

**Settings.**
- Purr: Parakeet v2 for English, and Whisper Large V3 Turbo with automatic language detection for the other languages. The 62 terms were in Words.
- Wispr Flow: English only for the English clips and language detection for the others. The 62 terms were in its Dictionary.
- Superwhisper: a Voice mode with the local Whisper Large V3 Turbo model. The 62 terms were in its vocabulary.

**Keep in mind.**
- Each clip was played once. The sets are small: one word moves the everyday score by 0.2 points.
- The audio is read speech (audiobooks and macOS voices), played digitally. A real microphone in a real room, and unscripted speech, are harder for all three apps.
- Speed depends on the Mac and, for Wispr Flow, on the network.
- Superwhisper has other local and cloud models, and Wispr Flow has paid plans. Neither was tested.
- Meeting recording wasn't compared.
- Purr's first nine everyday clips were played twice, because another app's dialog interrupted the first pass. Scores use the second run. Both runs are in [results/purr.tsv](head-to-head/results/purr.tsv).

## Purr on public test sets

These ran Purr's engines and prompts directly on standard datasets, without the app or BlackHole in between.

### Speech recognition

Word error rate on LibriSpeech (lower is better). Parakeet ran all 2,620 test-clean and 2,939 test-other files and Whisper every fourth file, scored with FluidAudio's normalizer. The normalizer differs from the head-to-head's, so compare within this table only.

| Engine | Purr uses it for | test-clean | test-other |
|---|---|---|---|
| Parakeet v2 | Dictation, Voice Edit, English meetings | **1.88%** | **3.31%** |
| Parakeet Ultra | Meetings in other languages | 1.89% | 3.53% |
| Whisper Large V3 | Whisper dictation | 2.03% | 4.42% |
| Whisper Large V3 Turbo | Whisper dictation | 2.02% | 4.62% |

### Names and terms (Words)

Words listens for the names and terms you add. Each LibriSpeech chapter's character and place names were added as Words:

| | Without Words | With Words |
|---|---|---|
| Names spelled right, test-clean | 82.5% | **95.0%** |
| Names spelled right, test-other | 72.4% | **90.5%** |
| Word error rate, test-clean | 1.88% | **1.64%** |
| Word error rate, test-other | 3.31% | **2.93%** |

Adding 40 terms that are never said changed a word in only 4 of 2,620 test-clean and 9 of 2,939 test-other dictations.

The head-to-head's 62 terms, read by 5 macOS voices (310 term uses): **213** spelled exactly right with Words, 145 without.

### Voice Edit

32 edits with one right answer each, run 3 times: **96 of 96** right with Gemma 4 E2B and 68 of 96 with Apple's on-device model.

### Who said what in meetings

On 16 meetings from the AMI corpus recorded with one distant microphone, the diarization error rate was **9.6%**. Purr found the right number of speakers in 15 of 16 meetings and ran 232 times faster than real time.

### Long meeting summaries

A generated 55-minute meeting with 38 action items, 26 decisions and 12 open questions. Each item is matched by word overlap to see whether the notes kept it:

| Kept in the notes | Gemma 4 E2B | Apple's on-device model |
|---|---|---|
| Action items | **36 of 38** | **36 of 38** |
| Decisions | 15 of 26 | **21 of 26** |
| Open questions | **11 of 12** | 10 of 12 |

## Numbers published by others

**Apple's speech recognition.** We didn't test Apple Dictation ourselves. An independent reproduction, [Inkvi/apple-speech-benchmark-repro](https://github.com/Inkvi/apple-speech-benchmark-repro), measured word error rate with OpenAI's normalizer:

| Set | Parakeet v2 (Purr's dictation model) | Apple SpeechAnalyzer (macOS 26) | Apple's older speech engine |
|---|---|---|---|
| LibriSpeech test-clean | **1.69%** | 1.82% | 8.65% |
| LibriSpeech test-other | | | 15.8% |
| Earnings-22 | **11.2%** | 12.0% | |
| AMI meetings | **11.6%** | 14.3% | |

That's about 5 times fewer errors than Apple's older engine on clean speech. Apple's newest engine comes close, but it needs macOS 26.

**Superwhisper's benchmark.** [superwhisper.com/benchmarks](https://superwhisper.com/benchmarks) runs Parakeet v2 (inside Superwhisper, with Superwhisper's vocabulary handling, not Purr's) and Wispr Flow on 8 English sets:
- Custom terms recognized on its phonetic vocabulary set: Parakeet v2 **71.4%**, Wispr Flow 61.4%.
- Custom terms recognized on earnings calls with a vocabulary list: Parakeet v2 **90.4%**, Wispr Flow 63.6%.
- Average word error rate over the 8 sets: Wispr Flow **8.7%**, Parakeet v2 10.4%.

## Run it yourself

You need a Mac with [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole), ffmpeg, the Xcode command line tools, Python 3 with `numpy` and `transformers` (for Whisper's text normalizers), and LibriSpeech [test-clean and test-other](https://www.openslr.org/12).

No audio is checked in, because Apple's license allows macOS voices for personal, non-commercial use only. The build scripts make every clip again from LibriSpeech and the voices on your Mac. The rebuilt clips match ours, except for three voices (Portuguese, Korean and Arabic) that vary slightly each time. If `say` reports a missing voice, add it in System Settings > Accessibility > Spoken Content > System Voice > Manage Voices.

```bash
cd benchmarks/head-to-head
python3 -I build.py ~/Downloads/LibriSpeech   # English clips and Voice Edit commands
python3 -I build_multi.py                      # 24 clips in 12 languages
for f in tools/*.swift; do swiftc -O "$f" -o "${f%.swift}"; done
touch test.txt && open -a TextEdit test.txt

zsh run.zsh purr .                             # or wispr, or sw (Superwhisper)
MANIFEST=bench/multi.tsv zsh run.zsh purr . purr-multi
zsh edit.zsh purr .                            # Voice Edit
python3 -I score.py purr wispr sw
python3 -I score_multi.py purr-multi wispr-multi sw-multi
```

Before running:
- Set each app's microphone to BlackHole 2ch, and add the words in `bench/words.txt` to its vocabulary.
- Give your terminal Accessibility access (for the key presses) and let it control TextEdit.
- Keep `test.txt` in front. If you touch the keyboard or mouse, or another window comes forward, the run stops.
- The second argument picks clips by id, e.g. `'^n'` for the everyday set. The Smart Typing run was `zsh run.zsh purr '^(n|l01)' purr-st` with Smart Typing turned on.

In `results/`, each `<run>.tsv` has one row per clip: its length, when the first and the last text arrived (seconds after key release) and the character count. `<run>/<clip>.txt` is exactly what the app typed. Runs are named `purr`, `wispr`, `sw` (Superwhisper), `purr-st` (Smart Typing), `*-multi` (other languages) and `edit-purr` (Voice Edit).
