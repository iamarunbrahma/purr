# Renders the multilingual dictation clips with macOS voices into bench/clips and
# writes bench/multi.tsv (same columns as manifest.tsv; terms holds the language code).
# usage: python3 -I build_multi.py
import os
import subprocess

B = os.path.dirname(os.path.abspath(__file__))
CL = f"{B}/bench/clips"
os.makedirs(CL, exist_ok=True)
LINES = [
    ("es", "Mónica", "Mañana tenemos una reunión con el equipo de ventas a las diez."),
    ("es", "Mónica", "Por favor, envíame el informe antes del viernes."),
    ("fr", "Thomas", "Je vais envoyer le rapport à toute l'équipe ce soir."),
    ("fr", "Thomas", "Pouvez-vous confirmer la date de la prochaine réunion ?"),
    ("de", "Anna", "Wir müssen das Budget für das nächste Quartal noch einmal prüfen."),
    ("de", "Anna", "Ich komme heute etwas später ins Büro."),
    ("it", "Alice", "Ho già prenotato il ristorante per sabato sera."),
    ("it", "Alice", "Il cliente vuole una risposta entro domani mattina."),
    ("pt", "Luciana", "Precisamos terminar a apresentação antes da reunião de amanhã."),
    ("pt", "Luciana", "Você pode me ligar depois do almoço?"),
    ("nl", "Xander", "Kun je de presentatie vandaag nog naar mij sturen?"),
    ("nl", "Xander", "De nieuwe versie van de app is klaar voor de test."),
    ("ru", "Milena", "Пожалуйста, отправьте мне отчёт до конца недели."),
    ("ru", "Milena", "Встреча перенесена на четверг."),
    ("hi", "Lekha", "कृपया कल सुबह तक रिपोर्ट भेज दीजिए।"),
    ("hi", "Lekha", "हमारी अगली मीटिंग सोमवार को होगी।"),
    ("ja", "Kyoko", "明日の会議は午後から始まります。"),
    ("ja", "Kyoko", "資料を今日中に送ってください。"),
    ("zh", "Tingting", "请在周五之前把报告发给我。"),
    ("zh", "Tingting", "我们下周一开会讨论这个问题。"),
    ("ko", "Yuna", "내일 오전에 회의가 있습니다."),
    ("ko", "Yuna", "보고서를 오늘까지 보내 주세요."),
    ("ar", "Majed", "من فضلك أرسل لي التقرير قبل نهاية الأسبوع."),
    ("ar", "Majed", "سيكون الاجتماع القادم يوم الاثنين."),
]
rows = ["id\tblock\tfile\tref\tterms\tnote"]
for i, (lang, voice, text) in enumerate(LINES, 1):
    cid = f"m{i:02d}"
    aiff, wav = f"{CL}/{cid}.aiff", f"{CL}/{cid}.wav"
    subprocess.run(["say", "-v", voice, "-o", aiff, text], check=True)
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-i",
            aiff,
            "-af",
            "adelay=300|300,apad=pad_dur=0.3",
            "-ar",
            "16000",
            "-ac",
            "1",
            "-sample_fmt",
            "s16",
            wav,
        ],
        check=True,
    )
    os.remove(aiff)
    rows.append(f"{cid}\tmulti\t{cid}.wav\t{text}\t{lang}\t{voice}")
open(f"{B}/bench/multi.tsv", "w").write("\n".join(rows) + "\n")
print(f"{len(LINES)} clips")
