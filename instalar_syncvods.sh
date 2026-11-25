#!/bin/bash
set -e

echo "============================================================"
echo "  INSTALADOR MASTER SYNC VODS - V47.5 UNIVERSAL GOLD (BR)"
echo "============================================================"

echo "[1/7] Configurando fuso horário do Brasil (America/Sao_Paulo)..."
timedatectl set-timezone America/Sao_Paulo 2>/dev/null || ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime

echo "[2/7] Atualizando o servidor e instalando dependências..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y > /dev/null 2>&1
apt-get install -y python3 python3-pip python3-venv sqlite3 ufw curl psmisc > /dev/null 2>&1

PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
apt-get install -y "python${PY_VER}-venv" python3-full > /dev/null 2>&1 || true
apt-get install -y default-mysql-client > /dev/null 2>&1 || apt-get install -y mariadb-client > /dev/null 2>&1 || apt-get install -y mysql-client > /dev/null 2>&1 || true

fuser -k 3000/tcp > /dev/null 2>&1 || true
killall gunicorn > /dev/null 2>&1 || true

echo "[3/7] Preparando ambiente virtual..."
DIR="/opt/xtream_importer"
mkdir -p "$DIR/templates"
cd "$DIR"
rm -rf "$DIR/venv" 2>/dev/null || true
python3 -m venv "$DIR/venv"
"$DIR/venv/bin/pip" install --upgrade pip -q
"$DIR/venv/bin/pip" install Flask Flask-SQLAlchemy Flask-Login requests pymysql werkzeug gunicorn cloudscraper -q

echo "[4/7] Construindo o Motor Universal V47.5 (XUI One / Xtream UI)..."
cat << 'EOF' > "$DIR/app.py"
from flask import Flask, render_template, request, redirect, url_for, flash, jsonify, g
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy import text
from flask_login import LoginManager, UserMixin, login_user, login_required, logout_user, current_user
from werkzeug.security import generate_password_hash, check_password_hash
from datetime import datetime, timedelta
from functools import wraps
import pymysql, requests, re, threading, time, uuid, json, urllib.parse, os

app = Flask(__name__)
app.secret_key = 'chave_super_secreta_syncvods_master'
app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///painel.db'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

TEMP_FILE = '/opt/xtream_importer/temp_lista_'
db = SQLAlchemy(app)
login_manager = LoginManager()
login_manager.init_app(app)
login_manager.login_view = 'login'
IMPORT_JOBS = {}

PLAN_LABELS = {
    'completo': 'Completo (Canais + Filmes + Séries)',
    'filmes_series': 'Filmes e Séries',
    'canais': 'Só Canais',
    'filmes': 'Só Filmes',
    'series': 'Só Séries',
    'canais_filmes': 'Canais e Filmes',
    'canais_series': 'Canais e Séries'
}

def plano_permite(plan_type, tipo_cat, role='client'):
    if role == 'admin': return True
    pt = (plan_type or 'completo').lower()
    if pt == 'completo': return True
    if tipo_cat == 'live': return pt in ['canais', 'canais_filmes', 'canais_series']
    if tipo_cat == 'movie': return pt in ['filmes', 'filmes_series', 'canais_filmes']
    if tipo_cat == 'series': return pt in ['series', 'filmes_series', 'canais_series']
    return True

class User(UserMixin, db.Model):
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(50), unique=True, nullable=False)
    password_hash = db.Column(db.String(200), nullable=False)
    plain_password = db.Column(db.String(50), nullable=True)
    whatsapp = db.Column(db.String(20), nullable=True)
    cpf = db.Column(db.String(20), nullable=True)
    role = db.Column(db.String(20), default='client')
    expiration = db.Column(db.DateTime, nullable=True)
    is_active = db.Column(db.Boolean, default=True)
    pending_days = db.Column(db.Integer, default=30)
    plan_type = db.Column(db.String(50), default='completo')

class XtreamConfig(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey('user.id'), nullable=False)
    panel_type = db.Column(db.String(20), default="xtream_ui")
    host = db.Column(db.String(100), default="localhost")
    port = db.Column(db.Integer, default=3306)
    user = db.Column(db.String(100), default="root")
    password = db.Column(db.String(200), default="")
    dbname = db.Column(db.String(100), default="xtream_iptvpro")
    tmdb_api_key = db.Column(db.String(100), default="f99aa9ae1fe7619969cc7db0938c1ae5")

class SystemSettings(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    whatsapp_api_url = db.Column(db.String(200), default="")
    whatsapp_instance = db.Column(db.String(100), default="")
    whatsapp_token = db.Column(db.String(200), default="")
    webhook_hash = db.Column(db.String(100), default=lambda: str(uuid.uuid4().hex))
    mp_access_token = db.Column(db.String(200), default="")
    asaas_api_key = db.Column(db.String(200), default="")

class Plan(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    category = db.Column(db.String(50), default="Mensal")
    price = db.Column(db.Float, nullable=False)
    days = db.Column(db.Integer, default=30)
    description = db.Column(db.String(300))

@login_manager.user_loader
def load_user(user_id): return User.query.get(int(user_id))

def send_whatsapp(number, message):
    if not number: return
    settings = SystemSettings.query.first()
    if settings and settings.whatsapp_api_url and settings.whatsapp_instance and settings.whatsapp_token:
        try:
            num = re.sub(r'\D', '', str(number))
            if len(num) in [10, 11]: num = "55" + num
            url = f"{settings.whatsapp_api_url.rstrip('/')}/message/sendText/{settings.whatsapp_instance}"
            headers = {"apikey": settings.whatsapp_token, "Authorization": f"Bearer {settings.whatsapp_token}", "Content-Type": "application/json"}
            payload = {"number": num, "options": {"delay": 1200}, "textMessage": {"text": message}}
            requests.post(url, json=payload, headers=headers, timeout=5)
        except: pass

def get_tutorial_msg(username, password, expiration_str, host_url):
    return f"""🎉 *ACESSO LIBERADO - SYNC VODS* 🎉\n\nOlá! A sua conta foi criada/ativada com sucesso.\n\n🌐 *Painel de Acesso:* {host_url}login\n👤 *Utilizador:* {username}\n🔑 *Palavra-passe:* {password}\n⏳ *Vencimento:* {expiration_str}\n\n*COMO USAR O SYNC VODS:*\n1️⃣ Aceda ao painel no link acima.\n2️⃣ Vá ao menu *Servidor* e ligue o seu banco de dados (Xtream UI ou XUI One).\n3️⃣ Volte ao *Início*, cole o link da sua lista M3U e clique em *Analisar Lista*.\n4️⃣ Selecione as categorias que deseja e clique em *INICIAR IMPORTAÇÃO*.\n5️⃣ Aguarde o sistema puxar tudo para o seu servidor! 🚀"""

def buscar_tmdb(titulo, tipo, api_key):
    if not api_key: return None
    url = f"https://api.themoviedb.org/3/search/{tipo}?api_key={api_key}&query={urllib.parse.quote(titulo)}&language=pt-BR"
    try:
        res = requests.get(url, timeout=3).json()
        if res.get('results'):
            item = res['results'][0]; img_base = "https://image.tmdb.org/t/p/w500"
            return {
                "tmdb_id": str(item.get('id', '')),
                "title": item.get('title') if tipo == 'movie' else item.get('name'),
                "cover": f"{img_base}{item['poster_path']}" if item.get('poster_path') else "",
                "plot": item.get('overview', ''),
                "rating": item.get('vote_average', 0),
                "release_date": item.get('release_date' if tipo == 'movie' else 'first_air_date', '')
            }
    except: pass
    return None

def limpar_nome(nome):
    n = re.sub(r'(?i)\[.*?\]|\(.*?\)', '', nome)
    n = re.sub(r'(?i)(?:S|T)\s*\d+\s*[\.\-\s_]*(?:E|EP)\s*\d+.*', '', n)
    n = re.sub(r'(?i)\b\d{1,2}\s*[xX]\s*\d{1,3}\b.*', '', n)
    n = re.sub(r'(?i)\btemp(?:orada)?\s*\d+.*', '', n)
    n = re.sub(r'(?i)\b(?:S|T)\d+\b.*', '', n)
    n = re.sub(r'[\-\|:]+$', '', n).strip()
    return n or nome.strip()

def extrair_temporada_episodio(nome):
    m = re.search(r'(?i)(?:S|T)\s*(\d+)\s*[\.\-\s_]*(?:E|EP)\s*(\d+)', nome)
    if m: return int(m.group(1)), int(m.group(2))
    m = re.search(r'(?i)\b(\d{1,2})\s*[xX]\s*(\d{1,3})\b', nome)
    if m: return int(m.group(1)), int(m.group(2))
    m = re.search(r'(?i)temp(?:orada)?\s*(\d+).*?ep(?:is[oó]dio)?\s*(\d+)', nome)
    if m: return int(m.group(1)), int(m.group(2))
    s, e = 1, 1
    ms = re.search(r'(?i)\b(?:S|T)(\d+)\b', nome)
    me = re.search(r'(?i)\b(?:E|EP)(\d+)\b', nome)
    if ms: s = int(ms.group(1))
    if me: e = int(me.group(1))
    return s, e

def inspecionar_banco(cursor):
    cursor.execute("SHOW TABLES")
    tables = {row[0] for row in cursor.fetchall()}
    schema = {}
    alvos = [
        'streams', 'streams_categories', 'stream_categories',
        'streams_series', 'series', 'streams_episodes', 'series_episodes',
        'streams_seasons', 'seasons', 'bouquets'
    ]
    for t in alvos:
        if t in tables:
            cursor.execute(f"DESCRIBE `{t}`")
            cols = {}
            for r in cursor.fetchall():
                cols[r[0]] = {
                    'type': str(r[1]).lower(),
                    'null': str(r[2]).upper() == 'YES',
                    'key': str(r[3]),
                    'default': r[4],
                    'extra': str(r[5]).lower()
                }
            schema[t] = cols
    return schema

def col_eh_numerica(schema, table, col):
    info = schema.get(table, {}).get(col)
    if not info: return False
    t = info['type']
    return any(k in t for k in ['int', 'float', 'double', 'decimal'])

def formatar_cat_id(schema, table, cat_id):
    if col_eh_numerica(schema, table, 'category_id'):
        return int(cat_id)
    return f"[{int(cat_id)}]"

def valor_padrao_coluna(col_type):
    if any(k in col_type for k in ['int', 'float', 'double', 'decimal']):
        return 0
    if 'json' in col_type:
        return '[]'
    if col_type == 'date':
        return '2000-01-01'
    if 'datetime' in col_type or 'timestamp' in col_type:
        return '2000-01-01 00:00:00'
    return ''

def insert_dinamico(cursor, schema, table, dados):
    cols_schema = schema.get(table, {})
    final = {}
    for k, v in dados.items():
        if k in cols_schema:
            final[k] = v
    for col, info in cols_schema.items():
        if col in final:
            continue
        if 'auto_increment' in info['extra']:
            continue
        if (not info['null']) and (info['default'] is None):
            final[col] = valor_padrao_coluna(info['type'])
    col_names = ", ".join(f"`{c}`" for c in final.keys())
    placeholders = ", ".join(["%s"] * len(final))
    cursor.execute(f"INSERT INTO `{table}` ({col_names}) VALUES ({placeholders})", tuple(final.values()))
    return cursor.lastrowid

def atualizar_seasons_serie(cursor, schema, t_ser, t_ep, serie_id, capa_fallback=""):
    if 'seasons' not in schema.get(t_ser, {}):
        return
    try:
        cursor.execute(f"SELECT season_num, COUNT(*) FROM `{t_ep}` WHERE series_id = %s GROUP BY season_num ORDER BY season_num ASC", (serie_id,))
        rows = cursor.fetchall()
        seasons_list = []
        for s_num, ep_cnt in rows:
            s_int = int(s_num or 1)
            seasons_list.append({
                "air_date": "",
                "episode_count": int(ep_cnt or 0),
                "id": s_int,
                "name": f"Temporada {s_int}",
                "overview": "",
                "poster_path": capa_fallback or "",
                "season_number": s_int
            })
        seasons_json = json.dumps(seasons_list, ensure_ascii=False)
        if 'last_modified' in schema[t_ser]:
            cursor.execute(f"UPDATE `{t_ser}` SET `seasons` = %s, `last_modified` = %s WHERE id = %s", (seasons_json, int(time.time()), serie_id))
        else:
            cursor.execute(f"UPDATE `{t_ser}` SET `seasons` = %s WHERE id = %s", (seasons_json, serie_id))
    except Exception:
        pass

def log_msg(job_id, msg):
    if len(IMPORT_JOBS[job_id]["logs"]) > 100: IMPORT_JOBS[job_id]["logs"].pop(0)
    IMPORT_JOBS[job_id]["logs"].append(f"[{time.strftime('%H:%M:%S')}] {msg}")

def adicionar_ao_relatorio(job_id, tipo, categoria, nome):
    if categoria not in IMPORT_JOBS[job_id]["relatorio"][tipo]: IMPORT_JOBS[job_id]["relatorio"][tipo][categoria] = []
    if nome not in IMPORT_JOBS[job_id]["relatorio"][tipo][categoria]: IMPORT_JOBS[job_id]["relatorio"][tipo][categoria].append(nome)

def limpa_array(str_val):
    if not str_val or str_val == 'null': return set()
    return set([int(x) for x in re.findall(r'\d+', str_val)])

@app.context_processor
def inject_status():
    if current_user.is_authenticated:
        config = XtreamConfig.query.filter_by(user_id=current_user.id).first()
        if config and config.password:
            try:
                conn = pymysql.connect(host=config.host, port=int(config.port), user=config.user, password=config.password, database=config.dbname, connect_timeout=2)
                conn.close()
                return dict(db_status=True)
            except: return dict(db_status=False)
    return dict(db_status=None)

@app.context_processor
def inject_plan_info():
    label = "Completo (Canais + Filmes + Séries)"
    if current_user.is_authenticated:
        if current_user.role == 'admin':
            label = "Administrador (Acesso Total)"
        else:
            label = PLAN_LABELS.get(getattr(current_user, 'plan_type', 'completo') or 'completo', 'Completo (Canais + Filmes + Séries)')
    return dict(plan_labels=PLAN_LABELS, current_plan_label=label)

@app.before_request
def check_expiration():
    if current_user.is_authenticated and current_user.role != 'admin':
        allowed_endpoints = ['aguardando_pagamento', 'verificar_pagamento', 'logout', 'static']
        if not current_user.is_active and request.endpoint not in allowed_endpoints: return redirect(url_for('aguardando_pagamento'))
        if current_user.is_active and current_user.expiration and current_user.expiration < datetime.now():
            if request.endpoint not in ['login', 'logout', 'static']:
                logout_user(); flash('A sua licença expirou!', 'warning'); return redirect(url_for('login'))

def admin_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if current_user.role != 'admin': flash('Acesso negado.', 'danger'); return redirect(url_for('dashboard'))
        return f(*args, **kwargs)
    return decorated_function

# ================= LOJA E PAGAMENTOS =================
@app.route('/')
def loja(): return render_template('loja.html', planos=Plan.query.all(), settings=SystemSettings.query.first())

@app.route('/checkout/<int:plan_id>', methods=['POST'])
def checkout(plan_id):
    plan = Plan.query.get_or_404(plan_id)
    username = request.form.get('username'); password = request.form.get('password'); whatsapp = request.form.get('whatsapp')
    cpf = request.form.get('cpf', ''); gateway = request.form.get('gateway'); cpf_limpo = re.sub(r'\D', '', cpf)
    settings = SystemSettings.query.first(); user = User.query.filter_by(username=username).first()
    exp_date = datetime.now() + timedelta(days=plan.days)

    if not user:
        user = User(username=username, password_hash=generate_password_hash(password), plain_password=password, whatsapp=whatsapp, cpf=cpf_limpo, role='client', is_active=False, pending_days=plan.days, expiration=exp_date)
        db.session.add(user); db.session.commit(); db.session.add(XtreamConfig(user_id=user.id)); db.session.commit()
    else:
        if user.is_active: flash('Este utilizador já existe.', 'warning'); return redirect(url_for('loja'))
        else: user.password_hash = generate_password_hash(password); user.plain_password = password; user.whatsapp = whatsapp; user.cpf = cpf_limpo; user.pending_days = plan.days; user.expiration = exp_date; db.session.commit()

    ref_id = f"{username}:{plan.days}"
    if gateway == 'mp' and settings and settings.mp_access_token:
        headers = {"Authorization": f"Bearer {settings.mp_access_token}", "Content-Type": "application/json"}
        payload = {"items": [{"title": f"SyncVods - {plan.name}", "quantity": 1, "unit_price": float(plan.price)}], "payer": {"name": username, "identification": {"type": "CPF", "number": cpf_limpo}}, "external_reference": ref_id, "back_urls": {"success": request.host_url.rstrip('/') + "/retorno_pagamento", "failure": request.host_url.rstrip('/') + "/", "pending": request.host_url.rstrip('/') + "/login"}, "auto_return": "approved", "notification_url": request.host_url.rstrip('/') + f"/webhook/{settings.webhook_hash}"}
        try:
            r = requests.post("https://api.mercadopago.com/checkout/preferences", json=payload, headers=headers)
            if r.status_code in [200, 201]: return redirect(r.json().get('init_point'))
        except: pass

    elif gateway == 'asaas' and settings and settings.asaas_api_key:
        headers = {"access_token": settings.asaas_api_key, "Content-Type": "application/json"}
        try:
            cus_res = requests.post("https://api.asaas.com/v3/customers", json={"name": username, "cpfCnpj": cpf_limpo, "mobilePhone": whatsapp}, headers=headers)
            if cus_res.status_code == 200 and cus_res.json().get('id'):
                pay_payload = {"customer": cus_res.json().get('id'), "billingType": "UNDEFINED", "value": float(plan.price), "dueDate": (datetime.now() + timedelta(days=1)).strftime('%Y-%m-%d'), "externalReference": ref_id, "description": f"Assinatura SyncVods - {plan.name}"}
                pay_res = requests.post("https://api.asaas.com/v3/payments", json=pay_payload, headers=headers)
                if pay_res.status_code == 200: return redirect(pay_res.json().get('invoiceUrl'))
        except: pass

    flash('Gateway indisponível.', 'danger'); return redirect(url_for('loja'))

@app.route('/retorno_pagamento')
def retorno_pagamento():
    if request.args.get('collection_status') == 'approved':
        ext_ref = request.args.get('external_reference')
        if ext_ref and ':' in ext_ref:
            username, days_str = ext_ref.split(':')
            user = User.query.filter_by(username=username).first()
            if user and not user.is_active:
                user.is_active = True
                if user.expiration and user.expiration < datetime.now(): user.expiration = datetime.now() + timedelta(days=int(days_str))
                db.session.commit()
                send_whatsapp(user.whatsapp, get_tutorial_msg(user.username, user.plain_password, user.expiration.strftime('%d/%m/%Y'), request.host_url))
                flash('Pagamento aprovado!', 'success')
    return redirect(url_for('login'))

@app.route('/webhook/<hash_code>', methods=['POST', 'GET'])
def webhook_pagamento(hash_code):
    settings = SystemSettings.query.first()
    if not settings or settings.webhook_hash != hash_code: return jsonify({"error": "Hash invalido"}), 403
    data = request.json or request.form or request.args

    if data.get('event') in ['PAYMENT_RECEIVED', 'PAYMENT_CONFIRMED']:
        ext_ref = data.get('payment', {}).get('externalReference', '')
        if ext_ref and ':' in ext_ref:
            username, days_str = ext_ref.split(':')
            user = User.query.filter_by(username=username).first()
            if user and not user.is_active:
                user.is_active = True
                if user.expiration and user.expiration < datetime.now(): user.expiration = datetime.now() + timedelta(days=int(days_str))
                db.session.commit()
                send_whatsapp(user.whatsapp, get_tutorial_msg(user.username, user.plain_password, user.expiration.strftime('%d/%m/%Y'), request.host_url))
        return jsonify({"status": "success"}), 200

    topic = request.args.get('topic') or data.get('type')
    payment_id = request.args.get('id') or data.get('data', {}).get('id')
    if (topic == 'payment' or topic == 'merchant_order') and payment_id and settings.mp_access_token:
        r = requests.get(f"https://api.mercadopago.com/v1/payments/{payment_id}", headers={"Authorization": f"Bearer {settings.mp_access_token}"})
        if r.status_code == 200 and r.json().get('status') == 'approved':
            ext_ref = r.json().get('external_reference', '')
            if ext_ref and ':' in ext_ref:
                username, days_str = ext_ref.split(':')
                user = User.query.filter_by(username=username).first()
                if user and not user.is_active:
                    user.is_active = True
                    if user.expiration and user.expiration < datetime.now(): user.expiration = datetime.now() + timedelta(days=int(days_str))
                    db.session.commit()
                    send_whatsapp(user.whatsapp, get_tutorial_msg(user.username, user.plain_password, user.expiration.strftime('%d/%m/%Y'), request.host_url))
        return jsonify({"status": "success"}), 200
    return jsonify({"status": "ignored"}), 200

# ================= LOGIN =================
@app.route('/login', methods=['GET', 'POST'])
def login():
    if current_user.is_authenticated: return redirect(url_for('dashboard'))
    if request.method == 'POST':
        user = User.query.filter_by(username=request.form.get('username')).first()
        if user and check_password_hash(user.password_hash, request.form.get('password')):
            login_user(user)
            if not user.is_active: return redirect(url_for('aguardando_pagamento'))
            if user.role != 'admin' and user.expiration and user.expiration < datetime.now():
                logout_user(); flash('Licença expirada.', 'warning'); return redirect(url_for('login'))
            return redirect(url_for('dashboard'))
        flash('Credenciais incorretas!', 'danger')
    return render_template('login.html')

@app.route('/aguardando_pagamento')
@login_required
def aguardando_pagamento():
    if current_user.is_active: return redirect(url_for('dashboard'))
    return render_template('aguardando_pagamento.html')

@app.route('/verificar_pagamento', methods=['POST'])
@login_required
def verificar_pagamento():
    if current_user.is_active: return redirect(url_for('dashboard'))
    settings = SystemSettings.query.first()
    ext_ref = f"{current_user.username}:{current_user.pending_days}"
    if settings and settings.mp_access_token:
        r = requests.get(f"https://api.mercadopago.com/v1/payments/search?external_reference={ext_ref}&status=approved", headers={"Authorization": f"Bearer {settings.mp_access_token}"})
        if r.status_code == 200 and r.json().get('results'):
            current_user.is_active = True
            if current_user.expiration and current_user.expiration < datetime.now(): current_user.expiration = datetime.now() + timedelta(days=current_user.pending_days)
            db.session.commit(); flash('Pagamento encontrado!', 'success')
            send_whatsapp(current_user.whatsapp, get_tutorial_msg(current_user.username, current_user.plain_password, current_user.expiration.strftime('%d/%m/%Y'), request.host_url))
            return redirect(url_for('dashboard'))
    if settings and settings.asaas_api_key:
        r = requests.get(f"https://api.asaas.com/v3/payments?externalReference={ext_ref}&status=RECEIVED", headers={"access_token": settings.asaas_api_key})
        if r.status_code == 200 and r.json().get('data'):
            current_user.is_active = True
            if current_user.expiration and current_user.expiration < datetime.now(): current_user.expiration = datetime.now() + timedelta(days=current_user.pending_days)
            db.session.commit(); flash('Pagamento encontrado!', 'success')
            send_whatsapp(current_user.whatsapp, get_tutorial_msg(current_user.username, current_user.plain_password, current_user.expiration.strftime('%d/%m/%Y'), request.host_url))
            return redirect(url_for('dashboard'))
    flash('Ainda não identificámos o pagamento aprovado.', 'warning'); return redirect(url_for('aguardando_pagamento'))

@app.route('/logout')
@login_required
def logout(): logout_user(); return redirect(url_for('login'))

@app.route('/dashboard')
@login_required
def dashboard(): return render_template('dashboard.html')

# ================= ADMIN E CONFIGURACOES =================
@app.route('/admin_panel', methods=['GET', 'POST'])
@login_required
@admin_required
def admin_panel():
    settings = SystemSettings.query.first()
    if request.method == 'POST':
        action = request.form.get('action')
        if action == 'create':
            username = request.form.get('username'); password = request.form.get('password'); whatsapp = request.form.get('whatsapp'); days = int(request.form.get('days', 30))
            if User.query.filter_by(username=username).first(): flash('O utilizador já existe!', 'danger')
            else:
                exp_date = datetime.now() + timedelta(days=days)
                plan_type = request.form.get('plan_type', 'completo')
                new_user = User(username=username, password_hash=generate_password_hash(password), plain_password=password, whatsapp=whatsapp, role='client', expiration=exp_date, plan_type=plan_type)
                db.session.add(new_user); db.session.commit()
                db.session.add(XtreamConfig(user_id=new_user.id)); db.session.commit()
                flash('Cliente criado!', 'success')
                send_whatsapp(whatsapp, get_tutorial_msg(username, password, exp_date.strftime('%d/%m/%Y'), request.host_url))
        elif action == 'edit_plan':
            user = User.query.get(request.form.get('user_id'))
            if user:
                user.plan_type = request.form.get('plan_type', 'completo')
                db.session.commit(); flash(f'Plano de {user.username} alterado para {PLAN_LABELS.get(user.plan_type, user.plan_type)}!', 'success')
        elif action == 'edit_expiration':
            user = User.query.get(request.form.get('user_id'))
            exp_str = (request.form.get('expiration') or '').strip()
            if user and exp_str:
                try:
                    if 'T' in exp_str:
                        user.expiration = datetime.strptime(exp_str[:16], '%Y-%m-%dT%H:%M')
                    else:
                        user.expiration = datetime.strptime(exp_str[:10], '%Y-%m-%d')
                    db.session.commit()
                    flash(f'Vencimento de {user.username} atualizado para {user.expiration.strftime("%d/%m/%Y %H:%M")}!', 'success')
                except Exception:
                    flash('Data de vencimento inválida!', 'danger')
        elif action == 'edit':
            user = User.query.get(request.form.get('user_id'))
            if user:
                user.username = request.form.get('username'); user.whatsapp = request.form.get('whatsapp')
                new_pass = request.form.get('password')
                if new_pass: user.password_hash = generate_password_hash(new_pass); user.plain_password = new_pass
                db.session.commit(); flash('Dados atualizados!', 'success')
        elif action == 'renew':
            user = User.query.get(request.form.get('user_id'))
            if user:
                days = int(request.form.get('days'))
                if user.expiration and user.expiration > datetime.now(): user.expiration += timedelta(days=days)
                else: user.expiration = datetime.now() + timedelta(days=days)
                user.is_active = True; db.session.commit(); flash('Renovado.', 'success')
                send_whatsapp(user.whatsapp, f"✅ *Renovação Concluída!*\n\nOlá {user.username}, a sua assinatura foi renovada!\n⏳ Novo Vencimento: {user.expiration.strftime('%d/%m/%Y')}")
        elif action == 'toggle':
            user = User.query.get(request.form.get('user_id'))
            if user and user.role != 'admin':
                user.is_active = not user.is_active; db.session.commit(); flash('Estado alterado.', 'success')
        elif action == 'delete':
            user = User.query.get(request.form.get('user_id'))
            if user and user.role != 'admin':
                XtreamConfig.query.filter_by(user_id=user.id).delete(); db.session.delete(user); db.session.commit(); flash('Apagado.', 'success')
        elif action == 'create_plan':
            novo_plano = Plan(name=request.form.get('plan_name'), category=request.form.get('category'), price=float(request.form.get('price')), days=int(request.form.get('days')), description=request.form.get('desc'))
            db.session.add(novo_plano); db.session.commit(); flash('Plano criado!', 'success')
        elif action == 'delete_plan':
            Plan.query.filter_by(id=request.form.get('plan_id')).delete(); db.session.commit(); flash('Plano apagado.', 'success')
        elif action == 'update_gateways':
            settings.mp_access_token = request.form.get('mp_access_token'); settings.asaas_api_key = request.form.get('asaas_api_key'); db.session.commit(); flash('Gateways guardados!', 'success')

    users = User.query.filter_by(role='client').all()
    planos = Plan.query.all()
    webhook_url = f"{request.host_url.rstrip('/')}/webhook/{settings.webhook_hash}" if settings else ""
    return render_template('admin_panel.html', users=users, planos=planos, now=datetime.now(), webhook_url=webhook_url, settings=settings)

@app.route('/configuracoes', methods=['GET', 'POST'])
@login_required
def configuracoes():
    config = XtreamConfig.query.filter_by(user_id=current_user.id).first()
    settings = SystemSettings.query.first()
    if request.method == 'POST':
        action = request.form.get('action')
        if action == 'update_xtream':
            config.panel_type = request.form.get('panel_type'); config.host = request.form.get('host'); config.port = int(request.form.get('port', 3306)); config.user = request.form.get('user'); config.password = request.form.get('password'); config.dbname = request.form.get('dbname'); config.tmdb_api_key = request.form.get('tmdb_api_key'); db.session.commit(); flash('Conexão guardada!', 'success')
        elif action == 'update_pass':
            new_user = request.form.get('admin_user'); new_pass = request.form.get('admin_pass')
            if new_user and new_user != current_user.username: current_user.username = new_user
            if new_pass: current_user.password_hash = generate_password_hash(new_pass); current_user.plain_password = new_pass
            db.session.commit(); flash('Acesso da conta atualizado com sucesso!', 'success')
        elif action == 'update_zap' and current_user.role == 'admin':
            settings.whatsapp_api_url = request.form.get('whatsapp_api_url'); settings.whatsapp_instance = request.form.get('whatsapp_instance'); settings.whatsapp_token = request.form.get('whatsapp_token'); db.session.commit(); flash('WhatsApp configurado!', 'success')
        return redirect(url_for('configuracoes'))
    return render_template('settings.html', config=config, settings=settings)

# ================= MOTOR DE IMPORTACAO UNIVERSAL (XUI ONE & XTREAM UI) =================
@app.route('/limpar_banco', methods=['POST'])
@login_required
def limpar_banco():
    dados = request.json; config = XtreamConfig.query.filter_by(user_id=current_user.id).first()
    if not config: return jsonify({"status": "error", "msg": "Config não encontrada"})
    try:
        conn = pymysql.connect(host=config.host, port=int(config.port), user=config.user, password=config.password, database=config.dbname, charset='utf8mb4')
        cursor = conn.cursor()
        schema = inspecionar_banco(cursor)
        t_cat = 'streams_categories' if 'streams_categories' in schema else 'stream_categories'
        t_ser = 'streams_series' if 'streams_series' in schema else 'series'
        t_ep = 'streams_episodes' if 'streams_episodes' in schema else 'series_episodes'
        t_sea = 'streams_seasons' if 'streams_seasons' in schema else ('seasons' if 'seasons' in schema else None)

        if dados.get('live'):
            cursor.execute("DELETE FROM streams WHERE type = 1 OR type = 8")
            if t_cat in schema: cursor.execute(f"DELETE FROM `{t_cat}` WHERE category_type = 'live'")
        if dados.get('vod'):
            cursor.execute("DELETE FROM streams WHERE type = 2")
            if t_cat in schema: cursor.execute(f"DELETE FROM `{t_cat}` WHERE category_type = 'movie'")
        if dados.get('series'):
            if t_ser in schema: cursor.execute(f"DELETE FROM `{t_ser}`")
            if t_ep in schema: cursor.execute(f"DELETE FROM `{t_ep}`")
            if t_sea and t_sea in schema:
                try: cursor.execute(f"DELETE FROM `{t_sea}`")
                except: pass
            cursor.execute("DELETE FROM streams WHERE type = 5")
            if t_cat in schema: cursor.execute(f"DELETE FROM `{t_cat}` WHERE category_type = 'series'")
        conn.commit(); conn.close()
        return jsonify({"status": "success", "msg": "Banco limpo!"})
    except Exception as e: return jsonify({"status": "error", "msg": str(e)})

def baixar_lista_blindada(link, user_id):
    user_file = f"{TEMP_FILE}{user_id}.m3u"
    if os.path.exists(user_file): os.remove(user_file)
    try:
        r = requests.get(link, headers={'User-Agent': 'IPTVSmartersPro'}, stream=True, timeout=15)
        if r.status_code == 200:
            with open(user_file, 'wb') as f:
                for chunk in r.iter_content(chunk_size=8192): f.write(chunk)
            if os.path.getsize(user_file) > 1000: return True
    except: pass
    return False

@app.route('/analisar_m3u', methods=['POST'])
@login_required
def analisar_m3u():
    file = request.files.get('m3u_file'); link = request.form.get('m3u_link')
    user_file = f"{TEMP_FILE}{current_user.id}.m3u"
    try:
        config = XtreamConfig.query.filter_by(user_id=current_user.id).first()
        bouquets_list = []
        try:
            conn = pymysql.connect(host=config.host, port=int(config.port), user=config.user, password=config.password, database=config.dbname, charset='utf8mb4')
            cursor = conn.cursor()
            cursor.execute("SELECT id, bouquet_name FROM bouquets ORDER BY bouquet_order ASC")
            for row in cursor.fetchall(): bouquets_list.append({"id": row[0], "name": row[1]})
            conn.close()
        except: pass

        if file and file.filename: file.save(user_file)
        elif link:
            if not baixar_lista_blindada(link, current_user.id): return jsonify({"status": "error", "msg": "Erro ao baixar"})
        else: return jsonify({"status": "error", "msg": "Nenhum arquivo"})

        categorias = set()
        with open(user_file, 'r', encoding='utf-8', errors='ignore') as f:
            for linha in f:
                if linha.startswith('#EXTINF'):
                    match = re.search(r'group-title=["\']?([^"\',]+)["\']?', linha)
                    if match: categorias.add(match.group(1).strip())
        return jsonify({"status": "success", "categorias": sorted(list(categorias)), "bouquets": bouquets_list})
    except Exception as e: return jsonify({"status": "error", "msg": str(e)})

def processar_importacao(job_id, categorias_selecionadas, bouquets_selecionados, config_id, user_id):
    conn = None
    try:
        with app.app_context():
            config = XtreamConfig.query.get(config_id)
            p_type = config.panel_type
            user_obj = User.query.get(user_id)
            user_plan = getattr(user_obj, 'plan_type', 'completo') if user_obj else 'completo'
            user_role = user_obj.role if user_obj else 'client'
            user_file = f"{TEMP_FILE}{user_id}.m3u"

            total = 0
            with open(user_file, 'r', encoding='utf-8', errors='ignore') as f:
                info_atual = None
                for linha in f:
                    linha = linha.strip()
                    if linha.startswith('#EXTINF'): info_atual = linha
                    elif linha.startswith('http') and info_atual:
                        match_cat = re.search(r'group-title=["\']?([^"\',]+)["\']?', info_atual)
                        if match_cat and match_cat.group(1).strip() in categorias_selecionadas: total += 1
                        info_atual = None
            IMPORT_JOBS[job_id]["total"] = total
            if total == 0:
                IMPORT_JOBS[job_id]["status"] = "concluido"
                return

            conn = pymysql.connect(host=config.host, port=int(config.port), user=config.user, password=config.password, database=config.dbname, charset='utf8mb4', connect_timeout=10)
            cursor = conn.cursor()
            schema = inspecionar_banco(cursor)

            is_xui = ('streams_series' in schema) or ('streams_categories' in schema) or (p_type == 'xui_one')
            t_cat = 'streams_categories' if 'streams_categories' in schema else 'stream_categories'
            t_ser = 'streams_series' if 'streams_series' in schema else 'series'
            t_ep = 'streams_episodes' if 'streams_episodes' in schema else 'series_episodes'
            t_sea = 'streams_seasons' if 'streams_seasons' in schema else ('seasons' if 'seasons' in schema else None)

            log_msg(job_id, f"🔍 Motor Universal ativo ({'XUI ONE' if is_xui else 'XTREAM UI'} | {t_ser} / {t_ep})")

            novos_canais_ids = set()
            novos_filmes_ids = set()
            novos_series_ids = set()
            series_capas = {}
            series_cache = {}
            cat_cache = {}

            def sincronizar_pendencias():
                try:
                    for sid in list(novos_series_ids):
                        atualizar_seasons_serie(cursor, schema, t_ser, t_ep, sid, series_capas.get(sid, ""))
                    if bouquets_selecionados and 'bouquets' in schema:
                        bq_cols = schema['bouquets']
                        tem_movies_col = 'bouquet_movies' in bq_cols
                        for bid in bouquets_selecionados:
                            if tem_movies_col:
                                cursor.execute("SELECT bouquet_channels, bouquet_movies, bouquet_series FROM bouquets WHERE id = %s", (bid,))
                                row = cursor.fetchone()
                                if row:
                                    c = limpa_array(row[0]); m = limpa_array(row[1]); s = limpa_array(row[2])
                                    c.update(novos_canais_ids); m.update(novos_filmes_ids); s.update(novos_series_ids)
                                    cursor.execute(
                                        "UPDATE bouquets SET bouquet_channels=%s, bouquet_movies=%s, bouquet_series=%s WHERE id=%s",
                                        (json.dumps(list(c), separators=(',', ':')), json.dumps(list(m), separators=(',', ':')), json.dumps(list(s), separators=(',', ':')), bid)
                                    )
                            else:
                                cursor.execute("SELECT bouquet_channels, bouquet_series FROM bouquets WHERE id = %s", (bid,))
                                row = cursor.fetchone()
                                if row:
                                    c = limpa_array(row[0]); s = limpa_array(row[1])
                                    c.update(novos_canais_ids); c.update(novos_filmes_ids); s.update(novos_series_ids)
                                    cursor.execute(
                                        "UPDATE bouquets SET bouquet_channels=%s, bouquet_series=%s WHERE id=%s",
                                        (json.dumps(list(c), separators=(',', ':')), json.dumps(list(s), separators=(',', ':')), bid)
                                    )
                    conn.commit()
                except Exception as err_sync:
                    log_msg(job_id, f"⚠️ Aviso ao sincronizar temporadas/bouquets: {err_sync}")

            i = 0
            with open(user_file, 'r', encoding='utf-8', errors='ignore') as f:
                info_atual = None
                for linha in f:
                    if IMPORT_JOBS[job_id].get("cancelar"):
                        sincronizar_pendencias()
                        break
                    while IMPORT_JOBS[job_id].get("pausado"):
                        time.sleep(1)
                    linha = linha.strip()
                    if linha.startswith('#EXTINF'):
                        info_atual = linha
                    elif linha.startswith('http') and info_atual:
                        match_cat = re.search(r'group-title=["\']?([^"\',]+)["\']?', info_atual)
                        cat_crua = match_cat.group(1).strip() if match_cat else ""
                        if cat_crua in categorias_selecionadas:
                            nome_match = re.search(r',(.*)$', info_atual)
                            nome_bruto = (nome_match.group(1) if nome_match else "Sem Nome").strip()
                            nome_limpo = limpar_nome(nome_bruto)
                            logo_match = re.search(r'tvg-logo="([^"]+)"', info_atual)
                            logo = logo_match.group(1) if logo_match else ""
                            cat_lower = cat_crua.lower()
                            url_lower = linha.lower()

                            is_serie_nome = bool(
                                re.search(r'(?i)(?:S|T)\s*\d+\s*[\.\-\s_]*(?:E|EP)\s*\d+', nome_bruto)
                                or re.search(r'(?i)\b\d{1,2}\s*[xX]\s*\d{1,3}\b', nome_bruto)
                                or re.search(r'(?i)temp(?:orada)?\s*\d+.*?ep(?:is[oó]dio)?\s*\d+', nome_bruto)
                            )

                            if '/series/' in url_lower:
                                tipo_cat = "series"; tipo_num = 5
                            elif '/movie/' in url_lower:
                                tipo_cat = "movie"; tipo_num = 2
                            elif "24h" in cat_lower or "canais" in cat_lower or "canal" in cat_lower or '/live/' in url_lower:
                                tipo_cat = "live"; tipo_num = 1
                            elif is_serie_nome or "série" in cat_lower or "serie" in cat_lower or "novela" in cat_lower or "dorama" in cat_lower:
                                tipo_cat = "series"; tipo_num = 5
                            elif "filme" in cat_lower or "vod" in cat_lower or url_lower.endswith(('.mp4', '.mkv', '.avi')):
                                tipo_cat = "movie"; tipo_num = 2
                            else:
                                tipo_cat = "live"; tipo_num = 1

                            if not plano_permite(user_plan, tipo_cat, user_role):
                                IMPORT_JOBS[job_id]["ignorados"] += 1
                                log_msg(job_id, f"🔒 [FORA DO PLANO] {nome_bruto}")
                                i += 1; IMPORT_JOBS[job_id]["atual"] = i; IMPORT_JOBS[job_id]["progress"] = int((i / total) * 100)
                                info_atual = None
                                continue

                            cat_key = (cat_crua, tipo_cat)
                            if cat_key in cat_cache:
                                cat_id = cat_cache[cat_key]
                            else:
                                cursor.execute(f"SELECT id FROM `{t_cat}` WHERE category_name = %s AND category_type = %s", (cat_crua, tipo_cat))
                                cat_row = cursor.fetchone()
                                if not cat_row:
                                    cat_id = insert_dinamico(cursor, schema, t_cat, {
                                        'category_type': tipo_cat,
                                        'category_name': cat_crua,
                                        'parent_id': 0,
                                        'cat_order': 0,
                                        'is_adult': 0
                                    })
                                    conn.commit()
                                else:
                                    cat_id = cat_row[0]
                                cat_cache[cat_key] = cat_id

                            cat_stream_val = formatar_cat_id(schema, 'streams', cat_id)
                            source_json = json.dumps([linha]).replace('/', r'\/')
                            now_ts = int(time.time())
                            ext = "mkv" if url_lower.endswith(".mkv") else ("avi" if url_lower.endswith(".avi") else "mp4")

                            if tipo_cat == "series":
                                s_n, e_n = extrair_temporada_episodio(nome_bruto)
                                cat_ser_val = formatar_cat_id(schema, t_ser, cat_id)

                                if nome_limpo in series_cache:
                                    serie_id, capa_serie = series_cache[nome_limpo]
                                else:
                                    cursor.execute(f"SELECT id, cover, category_id FROM `{t_ser}` WHERE title = %s", (nome_limpo,))
                                    ser_row = cursor.fetchone()
                                    if not ser_row:
                                        tmdb = buscar_tmdb(nome_limpo, 'tv', config.tmdb_api_key) or {}
                                        capa_serie = tmdb.get('cover') or logo
                                        sinopse_s = tmdb.get('plot') or ""
                                        rel_s = tmdb.get('release_date') or ""
                                        t_id_s = int(tmdb.get('tmdb_id')) if str(tmdb.get('tmdb_id', '')).isdigit() else 0
                                        t_rate_s = float(tmdb.get('rating') or 0)
                                        t_year_s = int(rel_s[:4]) if len(rel_s) >= 4 and rel_s[:4].isdigit() else 0

                                        ser_dados = {
                                            'title': nome_limpo,
                                            'category_id': cat_ser_val,
                                            'cover': capa_serie,
                                            'cover_big': capa_serie,
                                            'genre': '',
                                            'plot': sinopse_s,
                                            'cast': '',
                                            'rating': int(round(t_rate_s)) if 'int' in schema.get(t_ser, {}).get('rating', {}).get('type', '') else (t_rate_s if col_eh_numerica(schema, t_ser, 'rating') else str(t_rate_s)),
                                            'director': '',
                                            'release_date': rel_s,
                                            'releaseDate': rel_s,
                                            'last_modified': now_ts,
                                            'tmdb_id': t_id_s,
                                            'seasons': '[]',
                                            'episode_run_time': 45,
                                            'backdrop_path': json.dumps([capa_serie] if capa_serie else []),
                                            'youtube_trailer': '',
                                            'tmdb_language': 'pt',
                                            'year': t_year_s
                                        }
                                        serie_id = insert_dinamico(cursor, schema, t_ser, ser_dados)
                                        conn.commit()
                                    else:
                                        serie_id = ser_row[0]
                                        capa_serie = ser_row[1] or logo
                                        if not col_eh_numerica(schema, t_ser, 'category_id'):
                                            cur_c = str(ser_row[2] or '').strip()
                                            if not cur_c.startswith('['):
                                                cursor.execute(f"UPDATE `{t_ser}` SET category_id = %s WHERE id = %s", (cat_ser_val, serie_id))
                                                conn.commit()
                                    series_cache[nome_limpo] = (serie_id, capa_serie)

                                series_capas[serie_id] = capa_serie
                                novos_series_ids.add(serie_id)

                                if t_sea and t_sea in schema:
                                    try:
                                        sea_cols = schema[t_sea]
                                        if 'series_id' in sea_cols and 'season_num' in sea_cols:
                                            cursor.execute(f"SELECT 1 FROM `{t_sea}` WHERE series_id = %s AND season_num = %s LIMIT 1", (serie_id, s_n))
                                            if not cursor.fetchone():
                                                insert_dinamico(cursor, schema, t_sea, {'series_id': serie_id, 'season_num': s_n, 'season_name': f'Temporada {s_n}'})
                                                conn.commit()
                                        elif 'stream_id' in sea_cols and 'season_name' in sea_cols:
                                            cursor.execute(f"SELECT 1 FROM `{t_sea}` WHERE stream_id = %s AND season_name = %s LIMIT 1", (serie_id, str(s_n)))
                                            if not cursor.fetchone():
                                                insert_dinamico(cursor, schema, t_sea, {'stream_id': serie_id, 'season_name': str(s_n)})
                                                conn.commit()
                                    except Exception:
                                        pass

                                cursor.execute("SELECT id FROM streams WHERE type = 5 AND stream_display_name = %s LIMIT 1", (nome_bruto,))
                                st_ext = cursor.fetchone()
                                if st_ext:
                                    st_id = st_ext[0]
                                    cursor.execute(f"SELECT 1 FROM `{t_ep}` WHERE series_id = %s AND stream_id = %s LIMIT 1", (serie_id, st_id))
                                    if not cursor.fetchone():
                                        insert_dinamico(cursor, schema, t_ep, {
                                            'season_num': s_n,
                                            'series_id': serie_id,
                                            'stream_id': st_id,
                                            'episode_num': e_n,
                                            'sort': e_n
                                        })
                                        conn.commit()
                                        IMPORT_JOBS[job_id]["count_series"] += 1
                                        log_msg(job_id, f"🔗 [SÉRIE VINCULADA] {nome_limpo} - {nome_bruto}")
                                    else:
                                        IMPORT_JOBS[job_id]["ignorados"] += 1
                                else:
                                    ep_prop = json.dumps({
                                        "movie_image": logo or capa_serie,
                                        "plot": "",
                                        "releasedate": "",
                                        "rating": 0,
                                        "duration_secs": 2700,
                                        "duration": "00:45:00",
                                        "video": {"codec_name": "h264"},
                                        "audio": {"codec_name": "aac"}
                                    }, ensure_ascii=False)
                                    st_id = insert_dinamico(cursor, schema, 'streams', {
                                        'type': tipo_num,
                                        'category_id': cat_stream_val,
                                        'stream_display_name': nome_bruto,
                                        'stream_source': source_json,
                                        'stream_icon': logo or capa_serie,
                                        'direct_source': 1,
                                        'added': now_ts,
                                        'stream_all': 1,
                                        'target_container': json.dumps([ext]),
                                        'movie_properties': ep_prop,
                                        'movie_propeties': ep_prop
                                    })
                                    conn.commit()
                                    insert_dinamico(cursor, schema, t_ep, {
                                        'season_num': s_n,
                                        'series_id': serie_id,
                                        'stream_id': st_id,
                                        'episode_num': e_n,
                                        'sort': e_n
                                    })
                                    conn.commit()
                                    IMPORT_JOBS[job_id]["count_series"] += 1
                                    log_msg(job_id, f"🎬 [SÉRIE] {nome_limpo} (S{s_n:02d}E{e_n:02d})")
                                adicionar_ao_relatorio(job_id, 'series', cat_crua, nome_bruto)

                            elif tipo_cat == "movie":
                                cursor.execute("SELECT id FROM streams WHERE type = 2 AND stream_display_name = %s LIMIT 1", (nome_bruto,))
                                st_ext = cursor.fetchone()
                                if st_ext:
                                    IMPORT_JOBS[job_id]["ignorados"] += 1
                                    novos_filmes_ids.add(st_ext[0])
                                else:
                                    tmdb = buscar_tmdb(nome_limpo, 'movie', config.tmdb_api_key) or {}
                                    capa = tmdb.get('cover') or logo
                                    sinopse = tmdb.get('plot') or ""
                                    t_id = int(tmdb.get("tmdb_id")) if str(tmdb.get("tmdb_id", "")).isdigit() else 0
                                    t_rate = float(tmdb.get("rating") or 0)
                                    rel_date = tmdb.get("release_date") or ""
                                    t_year = int(rel_date[:4]) if len(rel_date) >= 4 and rel_date[:4].isdigit() else 0

                                    prop_dict = {
                                        "tmdb_id": str(t_id) if t_id else "",
                                        "name": nome_limpo, "o_name": nome_limpo,
                                        "movie_image": capa, "cover_big": capa,
                                        "description": sinopse, "plot": sinopse,
                                        "cast": "", "director": "", "genre": "",
                                        "release_date": rel_date, "releasedate": rel_date,
                                        "rating": str(t_rate), "year": str(t_year),
                                        "duration_secs": 7200, "duration": "02:00:00",
                                        "video": {"codec_name": "h264"}, "audio": {"codec_name": "aac"}
                                    }
                                    prop = json.dumps(prop_dict, ensure_ascii=False)
                                    st_id = insert_dinamico(cursor, schema, 'streams', {
                                        'type': tipo_num,
                                        'category_id': cat_stream_val,
                                        'stream_display_name': nome_bruto,
                                        'stream_source': source_json,
                                        'stream_icon': capa,
                                        'notes': sinopse,
                                        'direct_source': 1,
                                        'added': now_ts,
                                        'stream_all': 1,
                                        'target_container': json.dumps([ext]),
                                        'movie_properties': prop,
                                        'movie_propeties': prop,
                                        'tmdb_id': t_id,
                                        'rating': t_rate,
                                        'year': t_year
                                    })
                                    conn.commit()
                                    novos_filmes_ids.add(st_id)
                                    IMPORT_JOBS[job_id]["count_filmes"] += 1
                                log_msg(job_id, f"📽️ [FILME] {nome_bruto}")
                                adicionar_ao_relatorio(job_id, 'movie', cat_crua, nome_bruto)

                            else:
                                cursor.execute("SELECT id FROM streams WHERE type = 1 AND stream_display_name = %s LIMIT 1", (nome_bruto,))
                                st_ext = cursor.fetchone()
                                if st_ext:
                                    IMPORT_JOBS[job_id]["ignorados"] += 1
                                    novos_canais_ids.add(st_ext[0])
                                else:
                                    st_id = insert_dinamico(cursor, schema, 'streams', {
                                        'type': tipo_num,
                                        'category_id': cat_stream_val,
                                        'stream_display_name': nome_bruto,
                                        'stream_source': source_json,
                                        'stream_icon': logo,
                                        'direct_source': 1,
                                        'added': now_ts,
                                        'stream_all': 1
                                    })
                                    conn.commit()
                                    novos_canais_ids.add(st_id)
                                    IMPORT_JOBS[job_id]["count_canais"] += 1
                                log_msg(job_id, f"📺 [CANAL] {nome_bruto}")
                                adicionar_ao_relatorio(job_id, 'live', cat_crua, nome_bruto)

                            i += 1
                            IMPORT_JOBS[job_id]["atual"] = i
                            IMPORT_JOBS[job_id]["progress"] = int((i / total) * 100)
                            if i % 250 == 0:
                                sincronizar_pendencias()
                        info_atual = None

            if not IMPORT_JOBS[job_id].get("cancelar"):
                sincronizar_pendencias()
            conn.close()
            IMPORT_JOBS[job_id]["status"] = "cancelado" if IMPORT_JOBS[job_id].get("cancelar") else "concluido"
    except Exception as e:
        log_msg(job_id, f"❌ ERRO NA IMPORTAÇÃO: {e}")
        IMPORT_JOBS[job_id]["status"] = "erro"
        try:
            if conn: conn.close()
        except Exception:
            pass

@app.route('/iniciar_importacao', methods=['POST'])
@login_required
def iniciar_importacao():
    dados = request.json; job_id = str(uuid.uuid4())
    IMPORT_JOBS[job_id] = {"status": "rodando", "progress": 0, "total": 0, "atual": 0, "ignorados": 0, "logs": [], "pausado": False, "cancelar": False, "count_canais": 0, "count_filmes": 0, "count_series": 0, "user_id": current_user.id, "relatorio": {"movie": {}, "series": {}, "live": {}}}
    conf = XtreamConfig.query.filter_by(user_id=current_user.id).first()
    t = threading.Thread(target=processar_importacao, args=(job_id, dados.get('categorias', []), dados.get('bouquets', []), conf.id, current_user.id))
    t.daemon = True; t.start(); return jsonify({"status": "success", "job_id": job_id})

@app.route('/get_active_job')
@login_required
def get_active_job():
    for jid, jdata in IMPORT_JOBS.items():
        if jdata["status"] == "rodando" and jdata.get("user_id") == current_user.id:
            return jsonify({"status": "found", "job_id": jid})
    return jsonify({"status": "none"})

@app.route('/controle_job/<job_id>/<acao>', methods=['POST'])
@login_required
def controle_job(job_id, acao):
    if job_id in IMPORT_JOBS and IMPORT_JOBS[job_id].get("user_id") == current_user.id:
        if acao == 'pausar': IMPORT_JOBS[job_id]["pausado"] = True
        elif acao == 'continuar': IMPORT_JOBS[job_id]["pausado"] = False
        elif acao == 'cancelar': IMPORT_JOBS[job_id]["cancelar"] = True
        return jsonify({"status": "success"})
    return jsonify({"status": "error"})

@app.route('/status_importacao/<job_id>')
@login_required
def status_importacao(job_id):
    job = IMPORT_JOBS.get(job_id)
    if job and job.get("user_id") == current_user.id: return jsonify(job)
    return jsonify({"status": "nao_encontrado"})

@app.route('/gerar_relatorio/<job_id>')
@login_required
def gerar_relatorio(job_id):
    job = IMPORT_JOBS.get(job_id)
    if not job or job.get("user_id") != current_user.id: return jsonify({"texto": ""})

    total_importado = job["count_canais"] + job["count_filmes"] + job["count_series"]
    res = [f"Total importado para o servidor: {total_importado} conteúdos\n", f"Atualização conteúdos do dia: {time.strftime('%d/%m/%Y')}\n"]
    rel = job.get("relatorio", {})

    if rel.get("movie"):
        res.append("\n[FILMES]\n")
        for cat, itens in rel["movie"].items():
            res.append(f"📁 {cat}")
            for i in itens: res.append(f"📽️ {i}")
            res.append("")
    if rel.get("series"):
        res.append("\n[SÉRIES]\n")
        for cat, itens in rel["series"].items():
            res.append(f"📁 {cat}")
            for i in itens: res.append(f"🎬 {i}")
            res.append("")
    if rel.get("live"):
        res.append("\n[CANAIS]\n")
        for cat, itens in rel["live"].items():
            res.append(f"📁 {cat}")
            for i in itens: res.append(f"📺 {i}")
            res.append("")

    return jsonify({"texto": "\n".join(res)})

@app.route('/limpar_sessao', methods=['POST'])
@login_required
def limpar_sessao():
    chaves = list(IMPORT_JOBS.keys())
    for j in chaves:
        if IMPORT_JOBS[j]["status"] in ["concluido", "erro", "cancelado"] and IMPORT_JOBS[j].get("user_id") == current_user.id: del IMPORT_JOBS[j]
    return jsonify({"status": "success"})

# ================= MIGRACAO E INICIALIZACAO =================
with app.app_context():
    db.create_all()
    try: db.session.execute(text("ALTER TABLE user ADD COLUMN whatsapp VARCHAR(20) DEFAULT ''")); db.session.commit()
    except: db.session.rollback()
    try: db.session.execute(text("ALTER TABLE user ADD COLUMN cpf VARCHAR(20) DEFAULT ''")); db.session.commit()
    except: db.session.rollback()
    try: db.session.execute(text("ALTER TABLE user ADD COLUMN pending_days INTEGER DEFAULT 30")); db.session.commit()
    except: db.session.rollback()
    try: db.session.execute(text("ALTER TABLE user ADD COLUMN plan_type VARCHAR(50) DEFAULT 'completo'")); db.session.commit()
    except: db.session.rollback()
    try: db.session.execute(text("ALTER TABLE system_settings ADD COLUMN mp_access_token VARCHAR(200) DEFAULT ''")); db.session.commit()
    except: db.session.rollback()
    try: db.session.execute(text("ALTER TABLE system_settings ADD COLUMN asaas_api_key VARCHAR(200) DEFAULT ''")); db.session.commit()
    except: db.session.rollback()
    try: db.session.execute(text("ALTER TABLE system_settings ADD COLUMN whatsapp_instance VARCHAR(100) DEFAULT ''")); db.session.commit()
    except: db.session.rollback()

    try:
        if not User.query.filter_by(username='admin').first():
            master_admin = User(username='admin', password_hash=generate_password_hash('admin123'), role='admin')
            db.session.add(master_admin); db.session.commit()
            db.session.add(XtreamConfig(user_id=master_admin.id)); db.session.commit()
        if not SystemSettings.query.first(): db.session.add(SystemSettings()); db.session.commit()
    except: db.session.rollback()

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=3000)
EOF

echo "[5/7] Gerando todos os templates HTML..."
cat << 'EOF' > "$DIR/templates/base.html"
<!DOCTYPE html>
<html lang="pt-PT" data-bs-theme="dark">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Sync Vods - Painel</title>
<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css" rel="stylesheet">
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
<style>
body { background-color: #121212; font-family: 'Segoe UI', sans-serif; display: flex; flex-direction: column; min-height: 100vh; }
.content-wrapper { flex: 1; }
.card { background-color: #1e1e1e; border: 1px solid #333; }
footer { background-color: #1a1a1a; border-top: 1px solid #333; padding: 15px 0; margin-top: 40px; color: #888; }
.status-dot { display: inline-block; width: 10px; height: 10px; border-radius: 50%; margin-right: 8px; }
.dot-green { background-color: #20c997; box-shadow: 0 0 8px #20c997; animation: pulse 2s infinite; }
.dot-red { background-color: #ff4d4d; box-shadow: 0 0 8px #ff4d4d; }
.dot-gray { background-color: #adb5bd; }
@keyframes pulse { 0% { opacity: 1; } 50% { opacity: 0.5; } 100% { opacity: 1; } }
</style>
</head>
<body>
<div class="content-wrapper">
<nav class="navbar navbar-expand-lg navbar-dark mb-4" style="background-color: #1e1e1e; border-bottom: 1px solid #333;">
  <div class="container">
    <a class="navbar-brand fw-bold text-primary" href="{{ url_for('dashboard') }}"><i class="fa-solid fa-cloud-arrow-up me-2"></i>Sync Vods</a>
    <button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#navbarNav"><span class="navbar-toggler-icon"></span></button>
    <div class="collapse navbar-collapse" id="navbarNav">
      <ul class="navbar-nav ms-auto">
        <li class="nav-item"><a class="nav-link" href="{{ url_for('loja') }}" target="_blank"><i class="fa-solid fa-shop me-1"></i> Ver Loja</a></li>
        <li class="nav-item"><a class="nav-link" href="{{ url_for('dashboard') }}"><i class="fa-solid fa-house me-1"></i> Início</a></li>
        <li class="nav-item"><a class="nav-link" href="{{ url_for('configuracoes') }}"><i class="fa-solid fa-gear me-1"></i> Servidor</a></li>
        {% if current_user.is_authenticated and current_user.role == 'admin' %}<li class="nav-item"><a class="nav-link text-warning fw-bold" href="{{ url_for('admin_panel') }}"><i class="fa-solid fa-crown me-1"></i> Admin</a></li>{% endif %}
        {% if current_user.is_authenticated %}<li class="nav-item"><a class="nav-link text-danger fw-bold" href="{{ url_for('logout') }}"><i class="fa-solid fa-right-from-bracket me-1"></i> Sair</a></li>{% else %}<li class="nav-item"><a class="nav-link text-success fw-bold" href="{{ url_for('login') }}"><i class="fa-solid fa-right-to-bracket me-1"></i> Entrar</a></li>{% endif %}
      </ul>
    </div>
  </div>
</nav>
<div class="container px-3">
  {% with messages = get_flashed_messages(with_categories=true) %}{% if messages %}{% for category, message in messages %}
  <div class="alert alert-{{ category }} alert-dismissible fade show" role="alert">{{ message }}<button type="button" class="btn-close" data-bs-dismiss="alert"></button></div>
  {% endfor %}{% endif %}{% endwith %}
  {% block content %}{% endblock %}
</div>
</div>
<footer>
  <div class="container d-flex flex-column flex-md-row justify-content-between align-items-center">
    <div><small>Sync Vods &copy; 2026 - O melhor importador cloud do mercado.</small></div>
    {% if current_user.is_authenticated %}
    <div>
      {% if db_status == True %}
      <div class="px-3 py-2 mt-3 mt-md-0 rounded text-success" style="background-color: rgba(25,135,84,0.1); border: 1px solid #198754; font-weight: 700; font-size: 0.85rem;"><span class="status-dot dot-green"></span> BD CONECTADO</div>
      {% elif db_status == False %}
      <div class="px-3 py-2 mt-3 mt-md-0 rounded text-danger" style="background-color: rgba(220,53,69,0.1); border: 1px solid #dc3545; font-weight: 700; font-size: 0.85rem;"><span class="status-dot dot-red"></span> BD DESCONECTADO</div>
      {% else %}
      <div class="px-3 py-2 mt-3 mt-md-0 rounded text-secondary" style="background-color: rgba(108,117,125,0.1); border: 1px solid #6c757d; font-weight: 700; font-size: 0.85rem;"><span class="status-dot dot-gray"></span> BD NÃO CONFIGURADO</div>
      {% endif %}
    </div>
    {% endif %}
  </div>
</footer>
<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
EOF

cat << 'EOF' > "$DIR/templates/login.html"
{% extends "base.html" %}
{% block content %}
<div class="row justify-content-center mt-5">
  <div class="col-md-5">
    <div class="card p-4 shadow border-primary">
      <h4 class="text-center text-primary fw-bold mb-4"><i class="fa-solid fa-right-to-bracket me-2"></i>Entrar no Sync Vods</h4>
      <form method="POST">
        <div class="mb-3">
          <label class="form-label text-light small fw-bold">Utilizador</label>
          <input type="text" name="username" class="form-control bg-dark text-white" required autofocus>
        </div>
        <div class="mb-4">
          <label class="form-label text-light small fw-bold">Palavra-passe</label>
          <input type="password" name="password" class="form-control bg-dark text-white" required>
        </div>
        <button type="submit" class="btn btn-primary w-100 fw-bold py-2">Acessar Painel</button>
      </form>
    </div>
  </div>
</div>
{% endblock %}
EOF

cat << 'EOF' > "$DIR/templates/settings.html"
{% extends "base.html" %}
{% block content %}
<div class="row g-4">
  <div class="col-md-6">
    <div class="card p-4 shadow border-primary">
      <h5 class="text-primary fw-bold mb-3"><i class="fa-solid fa-database me-2"></i>Conexão do Servidor (Xtream UI / XUI One)</h5>
      <form method="POST">
        <input type="hidden" name="action" value="update_xtream">
        <div class="mb-2">
          <label class="form-label small fw-bold">Tipo de Painel</label>
          <select name="panel_type" class="form-select bg-dark text-white">
            <option value="xtream_ui" {% if config.panel_type == 'xtream_ui' %}selected{% endif %}>Xtream UI</option>
            <option value="xui_one" {% if config.panel_type == 'xui_one' %}selected{% endif %}>XUI One</option>
          </select>
        </div>
        <div class="row g-2 mb-2">
          <div class="col-8">
            <label class="form-label small fw-bold">Host / IP MySQL</label>
            <input type="text" name="host" class="form-control bg-dark text-white" value="{{ config.host }}" required>
          </div>
          <div class="col-4">
            <label class="form-label small fw-bold">Porta</label>
            <input type="number" name="port" class="form-control bg-dark text-white" value="{{ config.port }}" required>
          </div>
        </div>
        <div class="mb-2">
          <label class="form-label small fw-bold">Usuário MySQL</label>
          <input type="text" name="user" class="form-control bg-dark text-white" value="{{ config.user }}" required>
        </div>
        <div class="mb-2">
          <label class="form-label small fw-bold">Senha MySQL</label>
          <input type="password" name="password" class="form-control bg-dark text-white" value="{{ config.password }}">
        </div>
        <div class="mb-2">
          <label class="form-label small fw-bold">Banco de Dados</label>
          <input type="text" name="dbname" class="form-control bg-dark text-white" value="{{ config.dbname }}" required>
        </div>
        <div class="mb-3">
          <label class="form-label small fw-bold">TMDB API Key</label>
          <input type="text" name="tmdb_api_key" class="form-control bg-dark text-white" value="{{ config.tmdb_api_key }}">
        </div>
        <button type="submit" class="btn btn-primary w-100 fw-bold">Salvar Conexão</button>
      </form>
    </div>
  </div>

  <div class="col-md-6">
    <div class="card p-4 shadow border-warning mb-4">
      <h5 class="text-warning fw-bold mb-3"><i class="fa-solid fa-key me-2"></i>Alterar Acesso da Conta</h5>
      <form method="POST">
        <input type="hidden" name="action" value="update_pass">
        <div class="mb-2">
          <label class="form-label small fw-bold">Utilizador</label>
          <input type="text" name="admin_user" class="form-control bg-dark text-white" value="{{ current_user.username }}" required>
        </div>
        <div class="mb-3">
          <label class="form-label small fw-bold">Nova Palavra-passe</label>
          <input type="password" name="admin_pass" class="form-control bg-dark text-white" placeholder="Deixe vazio para manter">
        </div>
        <button type="submit" class="btn btn-warning w-100 fw-bold text-dark">Atualizar Acesso</button>
      </form>
    </div>

    {% if current_user.role == 'admin' %}
    <div class="card p-4 shadow border-success">
      <h5 class="text-success fw-bold mb-3"><i class="fa-brands fa-whatsapp me-2"></i>API WhatsApp (Evolution)</h5>
      <form method="POST">
        <input type="hidden" name="action" value="update_zap">
        <div class="mb-2">
          <label class="form-label small fw-bold">URL da API</label>
          <input type="text" name="whatsapp_api_url" class="form-control bg-dark text-white" value="{{ settings.whatsapp_api_url if settings else '' }}" placeholder="https://api.seudominio.com">
        </div>
        <div class="mb-2">
          <label class="form-label small fw-bold">Instância</label>
          <input type="text" name="whatsapp_instance" class="form-control bg-dark text-white" value="{{ settings.whatsapp_instance if settings else '' }}">
        </div>
        <div class="mb-3">
          <label class="form-label small fw-bold">Token / API Key</label>
          <input type="text" name="whatsapp_token" class="form-control bg-dark text-white" value="{{ settings.whatsapp_token if settings else '' }}">
        </div>
        <button type="submit" class="btn btn-success w-100 fw-bold">Salvar WhatsApp</button>
      </form>
    </div>
    {% endif %}
  </div>
</div>
{% endblock %}
EOF

cat << 'EOF' > "$DIR/templates/aguardando_pagamento.html"
{% extends "base.html" %}
{% block content %}
<div class="row justify-content-center mt-5">
  <div class="col-md-6">
    <div class="card p-4 text-center shadow border-warning">
      <h4 class="text-warning fw-bold mb-3"><i class="fa-solid fa-clock me-2"></i>Aguardando Pagamento</h4>
      <p class="text-light mb-4">A sua conta ainda não está ativa. Assim que concluir o pagamento, clique no botão abaixo para validar imediatamente.</p>
      <form method="POST" action="{{ url_for('verificar_pagamento') }}">
        <button type="submit" class="btn btn-success w-100 fw-bold py-2 mb-3">Já paguei — Verificar Agora</button>
      </form>
      <a href="{{ url_for('logout') }}" class="btn btn-outline-secondary w-100">Sair</a>
    </div>
  </div>
</div>
{% endblock %}
EOF

cat << 'EOF' > "$DIR/templates/admin_panel.html"
{% extends "base.html" %} {% block content %}

<div class="row mb-4">
    <div class="col-12">
        <div class="card p-3 shadow border-info" style="background-color: #1e252b;">
            <div class="d-flex justify-content-between align-items-center">
                <h5 class="mb-0 fw-bold text-info"><i class="fa-solid fa-server me-2"></i>Status da Ligação do seu Servidor Principal</h5>
                <div>
                {% if db_status == True %}
                    <span class="badge bg-success fs-6"><i class="fa-solid fa-circle-check me-1"></i> Conectado e Pronto</span>
                {% elif db_status == False %}
                    <span class="badge bg-danger fs-6"><i class="fa-solid fa-circle-xmark me-1"></i> Desconectado</span>
                {% else %}
                    <span class="badge bg-secondary fs-6"><i class="fa-solid fa-circle-exclamation me-1"></i> Não Configurado</span>
                {% endif %}
                </div>
            </div>
        </div>
    </div>
</div>

<ul class="nav nav-tabs mb-4" id="adminTabs">
  <li class="nav-item"><a class="nav-link active fw-bold text-warning" data-bs-toggle="tab" href="#clientesTab">Gestão de Clientes</a></li>
  <li class="nav-item"><a class="nav-link fw-bold text-info" data-bs-toggle="tab" href="#planosTab">Gestão de Planos (Loja)</a></li>
  <li class="nav-item"><a class="nav-link fw-bold text-success" data-bs-toggle="tab" href="#webhookTab">Integração Webhook</a></li>
</ul>

<div class="tab-content">
  <div class="tab-pane fade show active" id="clientesTab">
      <div class="card p-3 mb-4 shadow border-success">
          <h5 class="text-white fw-bold mb-3">Criar Novo Cliente</h5>
          <form method="POST" class="row g-2">
              <input type="hidden" name="action" value="create">
              <div class="col-md-2"><input type="text" name="username" class="form-control bg-dark text-white" placeholder="Utilizador" required></div>
              <div class="col-md-2"><input type="text" name="password" class="form-control bg-dark text-white" placeholder="Palavra-passe" required></div>
              <div class="col-md-2"><input type="text" name="whatsapp" class="form-control bg-dark text-white" placeholder="WhatsApp (5511999999999)"></div>
              <div class="col-md-3">
                  <select name="plan_type" class="form-select bg-dark text-warning fw-bold">
                      {% for key, label in plan_labels.items() %}
                      <option value="{{ key }}">{{ label }}</option>
                      {% endfor %}
                  </select>
              </div>
              <div class="col-md-2"><select name="days" class="form-select bg-dark text-white"><option value="1">1 Dia</option><option value="30" selected>30 Dias</option></select></div>
              <div class="col-md-1"><button type="submit" class="btn btn-success w-100 fw-bold">+</button></div>
          </form>
      </div>
      <div class="card p-3 shadow border-secondary">
          <h5 class="text-white fw-bold mb-3">Clientes Ativos</h5>
          <div class="table-responsive">
              <table class="table table-dark table-bordered text-center align-middle">
                  <thead><tr><th>ID</th><th>Utilizador</th><th>Plano</th><th>Vencimento</th><th>Renovar</th><th>Ações</th></tr></thead>
                  <tbody>
                      {% for u in users %}
                      <tr>
                          <td>{{ u.id }}</td>
                          <td class="text-info">{{ u.username }}</td>
                          <td>
                              <form method="POST" class="d-flex justify-content-center gap-1">
                                  <input type="hidden" name="action" value="edit_plan">
                                  <input type="hidden" name="user_id" value="{{ u.id }}">
                                  <select name="plan_type" class="form-select form-select-sm w-auto bg-dark text-warning fw-bold">
                                      {% for key, label in plan_labels.items() %}
                                      <option value="{{ key }}" {% if (u.plan_type or 'completo') == key %}selected{% endif %}>{{ label }}</option>
                                      {% endfor %}
                                  </select>
                                  <button class="btn btn-sm btn-warning text-dark fw-bold" title="Salvar Plano"><i class="fa-solid fa-check"></i></button>
                              </form>
                          </td>
                          <td>
                              <form method="POST" class="d-flex justify-content-center gap-1">
                                  <input type="hidden" name="action" value="edit_expiration">
                                  <input type="hidden" name="user_id" value="{{ u.id }}">
                                  <input type="datetime-local" name="expiration" class="form-control form-control-sm bg-dark text-white" style="min-width: 175px;" value="{{ u.expiration.strftime('%Y-%m-%dT%H:%M') if u.expiration else '' }}" required>
                                  <button class="btn btn-sm btn-info text-dark fw-bold" title="Salvar Vencimento"><i class="fa-solid fa-check"></i></button>
                              </form>
                          </td>
                          <td><form method="POST" class="d-flex justify-content-center gap-1"><input type="hidden" name="action" value="renew"><input type="hidden" name="user_id" value="{{ u.id }}"><select name="days" class="form-select form-select-sm w-auto bg-dark text-white"><option value="30">+30 Dias</option></select><button class="btn btn-sm btn-primary">Renovar</button></form></td>
                          <td>
                              <div class="d-flex justify-content-center gap-1">
                                  <button type="button" class="btn btn-sm btn-info text-dark fw-bold" onclick="abrirInfo('{{ u.username }}', '{{ u.plain_password }}', '{{ u.whatsapp }}', '{{ u.expiration.strftime('%d/%m/%Y') if u.expiration else 'Nunca' }}')" title="Ver Mensagem Tutorial"><i class="fa-solid fa-eye"></i></button>
                                  <form method="POST" class="d-inline" onsubmit="return confirm('Excluir?');"><input type="hidden" name="action" value="delete"><input type="hidden" name="user_id" value="{{ u.id }}"><button class="btn btn-sm btn-danger"><i class="fa-solid fa-trash"></i></button></form>
                              </div>
                          </td>
                      </tr>
                      {% endfor %}
                  </tbody>
              </table>
          </div>
      </div>
  </div>

  <div class="tab-pane fade" id="planosTab">
      <div class="card p-3 mb-4 shadow border-info">
          <h5 class="text-white fw-bold mb-3">Adicionar Plano na Loja</h5>
          <form method="POST" class="row g-2">
              <input type="hidden" name="action" value="create_plan">
              <div class="col-md-3"><input type="text" name="plan_name" class="form-control bg-dark text-white" placeholder="Nome Ex: Filmes e Séries" required></div>
              <div class="col-md-2"><select name="category" class="form-select bg-dark text-white"><option value="Mensal">Assinatura Mensal</option><option value="Unica">Sincronia Única (24h)</option></select></div>
              <div class="col-md-2"><input type="number" step="0.01" name="price" class="form-control bg-dark text-white" placeholder="Preço R$" required></div>
              <div class="col-md-2"><input type="number" name="days" class="form-control bg-dark text-white" placeholder="Dias (Ex: 30)" required></div>
              <div class="col-md-3"><button type="submit" class="btn btn-info w-100 fw-bold text-dark">Registar Plano</button></div>
          </form>
      </div>
      <div class="card p-3 shadow border-secondary">
          <table class="table table-dark table-bordered text-center align-middle">
              <thead><tr><th>Nome</th><th>Tipo</th><th>Preço</th><th>Duração (Dias)</th><th>Ação</th></tr></thead>
              <tbody>{% for p in planos %}<tr><td>{{ p.name }}</td><td>{{ p.category }}</td><td>R$ {{ "%.2f"|format(p.price) }}</td><td>{{ p.days }}</td><td><form method="POST"><input type="hidden" name="action" value="delete_plan"><input type="hidden" name="plan_id" value="{{ p.id }}"><button class="btn btn-sm btn-danger"><i class="fa-solid fa-trash"></i></button></form></td></tr>{% endfor %}</tbody>
          </table>
      </div>
  </div>

  <div class="tab-pane fade" id="webhookTab">
      <div class="card p-4 shadow border-success mb-4">
          <h5 class="text-success fw-bold mb-3"><i class="fa-solid fa-money-bill-wave me-2"></i>Credenciais de Pagamento (Mercado Pago / Asaas)</h5>
          <form method="POST">
              <input type="hidden" name="action" value="update_gateways">
              <label class="text-info small fw-bold">Mercado Pago - Access Token</label>
              <input type="text" class="form-control bg-dark text-white mb-3" name="mp_access_token" value="{{ settings.mp_access_token if settings else '' }}" placeholder="APP_USR-123456789...">
              <label class="text-info small fw-bold">Asaas - API Key</label>
              <input type="text" class="form-control bg-dark text-white mb-3" name="asaas_api_key" value="{{ settings.asaas_api_key if settings else '' }}" placeholder="$aact_YTU5YTE0M2M...">
              <button class="btn btn-success fw-bold w-100">Guardar Gateways</button>
          </form>
      </div>
      <div class="card p-4 shadow border-secondary">
          <h5 class="text-white fw-bold mb-3"><i class="fa-solid fa-link me-2"></i>URL do Webhook</h5>
          <input type="text" class="form-control bg-black text-warning fw-bold mb-3 p-3 fs-5" value="{{ webhook_url }}" readonly>
      </div>
  </div>
</div>

<div class="modal fade" id="modalInfo" tabindex="-1">
  <div class="modal-dialog modal-dialog-centered">
    <div class="modal-content bg-dark border-info">
      <div class="modal-header border-secondary">
        <h5 class="modal-title text-info fw-bold"><i class="fa-solid fa-share-nodes me-2"></i>Enviar Acesso & Tutorial</h5>
        <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal"></button>
      </div>
      <div class="modal-body">
        <p class="text-muted small mb-2">Copie a mensagem abaixo ou envie diretamente pelo WhatsApp Web.</p>
        <textarea id="infoText" class="form-control bg-black text-success border-secondary mb-3" rows="12" readonly style="resize:none; font-family: monospace;"></textarea>
        <div class="d-flex gap-2">
          <button class="btn btn-secondary flex-grow-1 fw-bold py-2" onclick="copiarInfo()"><i class="fa-regular fa-copy me-2"></i> Copiar</button>
          <button class="btn btn-success flex-grow-1 fw-bold py-2" id="infoZapBtn"><i class="fa-brands fa-whatsapp me-2"></i> Abrir WhatsApp</button>
        </div>
      </div>
    </div>
  </div>
</div>

<script>
function abrirInfo(user, pass, zap, exp) {
    let host = window.location.origin;
    let msg = `🎉 *ACESSO LIBERADO - SYNC VODS* 🎉\n\nOlá! A sua conta foi criada/ativada com sucesso.\n\n🌐 *Painel de Acesso:* ${host}/login\n👤 *Utilizador:* ${user}\n🔑 *Palavra-passe:* ${pass}\n⏳ *Vencimento:* ${exp}\n\n*COMO USAR O SYNC VODS:*\n1️⃣ Aceda ao painel no link acima.\n2️⃣ Vá ao menu *Servidor* e ligue o seu banco de dados (Xtream UI ou XUI One).\n3️⃣ Volte ao *Início*, cole o link da sua lista M3U e clique em *Analisar Lista*.\n4️⃣ Selecione as categorias que deseja e clique em *INICIAR IMPORTAÇÃO*.\n5️⃣ Aguarde o sistema puxar tudo para o seu servidor! 🚀`;
    document.getElementById('infoText').value = msg;
    document.getElementById('infoZapBtn').onclick = function() {
        let num = zap ? zap.replace(/\D/g, '') : '';
        if (num.length === 10 || num.length === 11) num = "55" + num;
        window.open(`https://api.whatsapp.com/send?phone=${num}&text=${encodeURIComponent(msg)}`, '_blank');
    };
    new bootstrap.Modal(document.getElementById('modalInfo')).show();
}
function copiarInfo() {
    document.getElementById("infoText").select();
    document.execCommand("copy");
    alert("Mensagem copiada para a área de transferência!");
}
</script>
{% endblock %}
EOF

cat << 'EOF' > "$DIR/templates/dashboard.html"
{% extends "base.html" %} {% block content %}
<div class="row mb-4 d-flex justify-content-between align-items-center">
    <div class="col-7"><h4 class="fw-bold m-0 text-white">Gerenciador de Importação</h4></div>
    <div class="col-5 text-end"><button class="btn btn-sm btn-danger fw-bold shadow" data-bs-toggle="modal" data-bs-target="#modalLimpeza"><i class="fa-solid fa-trash"></i> Limpar DB</button></div>
</div>

<div class="row mb-4">
    <div class="col-12">
        <div class="card p-3 shadow-sm border-info" style="background-color: #1b222c;">
            <div class="d-flex flex-column flex-md-row justify-content-between align-items-md-center gap-2">
                <div>
                    <span class="text-secondary small fw-bold d-block">SEU PLANO ATUAL</span>
                    <span class="badge bg-info text-dark fs-6 mt-1"><i class="fa-solid fa-layer-group me-1"></i> {{ current_plan_label }}</span>
                </div>
                <div class="text-md-end">
                    <span class="text-secondary small fw-bold d-block">DATA DE VENCIMENTO</span>
                    <span class="badge bg-warning text-dark fs-6 mt-1"><i class="fa-solid fa-calendar-days me-1"></i> {{ current_user.expiration.strftime('%d/%m/%Y %H:%M') if current_user.expiration else 'Ilimitado' }}</span>
                </div>
            </div>
        </div>
    </div>
</div>

<div class="modal fade" id="modalLimpeza"><div class="modal-dialog modal-dialog-centered"><div class="modal-content bg-dark border-secondary"><div class="modal-header border-secondary"><h5 class="modal-title text-danger fw-bold"><i class="fa-solid fa-triangle-exclamation me-2"></i> Apagar Dados</h5><button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal"></button></div><div class="modal-body"><div class="form-check form-switch fs-5 mb-3"><input type="checkbox" class="form-check-input" id="wipeLive"><label class="form-check-label text-info"><i class="fa-solid fa-tv me-2"></i>Canais</label></div><div class="form-check form-switch fs-5 mb-3"><input type="checkbox" class="form-check-input" id="wipeVod"><label class="form-check-label text-warning"><i class="fa-solid fa-film me-2"></i>Filmes</label></div><div class="form-check form-switch fs-5"><input type="checkbox" class="form-check-input" id="wipeSeries"><label class="form-check-label text-success"><i class="fa-solid fa-video me-2"></i>Séries</label></div></div><div class="modal-footer border-secondary"><button type="button" class="btn btn-secondary" data-bs-dismiss="modal">Cancelar</button><button type="button" class="btn btn-danger fw-bold w-100 mt-2" onclick="executarLimpeza()">Confirmar Exclusão</button></div></div></div></div>

<div class="row" id="areaConfig">
    <div class="col-12">
        <div class="card p-3 mb-4 shadow-sm border-primary">
            <input type="url" class="form-control py-2 mb-3 bg-dark text-white" id="m3u_link" placeholder="Cole o link M3U aqui...">
            <button class="btn btn-primary w-100 fw-bold py-2 fs-5" id="btnAnalisar" onclick="analisarLista()"> Analisar Lista</button>
        </div>
        <div class="card p-3 shadow-sm mb-4" id="areaCategorias" style="display:none;">
            <div class="row">
                <div class="col-md-6 mb-3">
                    <h5 class="fw-bold text-info"><i class="fa-solid fa-list me-2"></i>Categorias</h5>
                    <div class="d-flex gap-2 mb-2"><button class="btn btn-sm btn-outline-info flex-grow-1" onclick="selecionarTodos('.cat-checkbox', true)">Marcar Todos</button><button class="btn btn-sm btn-outline-secondary flex-grow-1" onclick="selecionarTodos('.cat-checkbox', false)">Desmarcar</button></div>
                    <div id="listaCategorias" class="bg-black rounded p-2" style="height:250px; overflow-y:auto; border:1px solid #444;"></div>
                </div>
                <div class="col-md-6 mb-3">
                    <h5 class="fw-bold text-warning"><i class="fa-solid fa-box-open me-2"></i>Bouquets (Pacotes)</h5>
                    <div class="d-flex gap-2 mb-2"><button class="btn btn-sm btn-outline-warning flex-grow-1" onclick="selecionarTodos('.bq-checkbox', true)">Marcar Todos</button><button class="btn btn-sm btn-outline-secondary flex-grow-1" onclick="selecionarTodos('.bq-checkbox', false)">Desmarcar</button></div>
                    <div id="listaBouquets" class="bg-black rounded p-2" style="height:250px; overflow-y:auto; border:1px solid #444;"></div>
                </div>
            </div>
            <button class="btn btn-success w-100 py-3 fs-5 fw-bold shadow mt-2" onclick="iniciarImportacaoReal()"> INICIAR IMPORTAÇÃO</button>
        </div>
    </div>
</div>

<div class="row" id="areaProgresso" style="display:none;">
    <div class="col-12">
        <div class="card p-3 border-primary shadow">
            <h5 class="text-primary mb-3 fw-bold" id="textStatus"><i class="fa-solid fa-gears fa-spin me-2" id="iconStatus"></i> Importando...</h5>
            <div class="row mb-3 text-center g-2">
                <div class="col-4"><div class="border rounded p-2" style="background-color: #1a1a2e; border-color: #0f3460 !important;"><div class="small text-info fw-bold"><i class="fa-solid fa-tv me-1"></i> Canais</div><h4 class="m-0 text-white fw-bold" id="countCanais">0</h4></div></div>
                <div class="col-4"><div class="border rounded p-2" style="background-color: #2a1b1b; border-color: #601515 !important;"><div class="small text-danger fw-bold"><i class="fa-solid fa-film me-1"></i> Filmes</div><h4 class="m-0 text-white fw-bold" id="countFilmes">0</h4></div></div>
                <div class="col-4"><div class="border rounded p-2" style="background-color: #1b2a1c; border-color: #1e5a22 !important;"><div class="small text-success fw-bold"><i class="fa-solid fa-video me-1"></i> Séries</div><h4 class="m-0 text-white fw-bold" id="countSeries">0</h4></div></div>
            </div>
            <div class="d-flex justify-content-between mb-1 small"><span class="fw-bold" id="txtProgresso">Calculando...</span><span class="badge bg-danger ms-auto me-2" id="txtIgnorados">0 Pulados</span><span class="fw-bold" id="txtPorcentagem">0%</span></div>
            <div class="progress mb-3" style="height:22px; background-color:#222; border-radius:10px;"><div id="barraProgresso" class="progress-bar bg-success progress-bar-animated progress-bar-striped fw-bold" style="width:0%; line-height:22px;"></div></div>
            <div id="logTerminal" class="bg-black text-success p-2 rounded mb-3" style="height:220px; overflow-y:auto; border:1px solid #444; font-family: monospace;"></div>

            <div id="areaRelatorio" style="display:none;" class="mt-2 mb-3">
                <h6 class="fw-bold text-white"><i class="fa-brands fa-whatsapp text-success me-2"></i>Relatório da Atualização</h6>
                <textarea id="textoRelatorio" class="form-control bg-black text-white mb-2" style="height: 180px; font-size:12px; resize:none;" readonly></textarea>
                <div class="d-flex gap-2 mb-2"><button class="btn btn-secondary flex-grow-1 fw-bold" onclick="copiarRelatorio()"><i class="fa-regular fa-copy me-2"></i>Copiar</button><button class="btn btn-success flex-grow-1 fw-bold" onclick="enviarRelatorioZap()"><i class="fa-brands fa-whatsapp me-2"></i>Enviar WhatsApp</button></div>
            </div>

            <div class="d-flex gap-2 mb-3" id="areaControles">
                <button class="btn btn-warning flex-grow-1 fw-bold py-2" id="btnPausar" onclick="controleJob('pausar')"> Pausar</button>
                <button class="btn btn-success flex-grow-1 fw-bold py-2" id="btnContinuar" onclick="controleJob('continuar')" style="display:none;"> Continuar</button>
                <button class="btn btn-danger flex-grow-1 fw-bold py-2" onclick="controleJob('cancelar')"> Cancelar e Finalizar</button>
            </div>
            <button class="btn btn-outline-primary w-100 fw-bold py-3 fs-5" id="btnNova" style="display:none;" onclick="location.reload()"> Nova Importação</button>
        </div>
    </div>
</div>

<script>
let currentJobId = null, monitorInterval = null;
window.onload = () => { fetch('/get_active_job').then(r=>r.json()).then(d=>{if(d.status==='found'){currentJobId=d.job_id; document.getElementById('areaConfig').style.display='none'; document.getElementById('areaProgresso').style.display='block'; monitorInterval=setInterval(verificarStatus, 1000);}}); };

function executarLimpeza() { const d={live:document.getElementById('wipeLive').checked, vod:document.getElementById('wipeVod').checked, series:document.getElementById('wipeSeries').checked}; if(!d.live && !d.vod && !d.series) return alert("Selecione um item!"); if(confirm("Certeza absoluta?")) fetch('/limpar_banco',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(d)}).then(r=>r.json()).then(res=>{alert(res.msg); location.reload();}); }

function selecionarTodos(c, e) { document.querySelectorAll(c).forEach(x=>x.checked=e); }

function analisarLista() {
    const fd = new FormData(); fd.append('m3u_link', document.getElementById('m3u_link').value);
    document.getElementById('btnAnalisar').innerText = 'Aguarde...';
    fetch('/analisar_m3u',{method:'POST',body:fd}).then(r=>r.json()).then(d=>{
        if(d.status==='success'){
            document.getElementById('areaCategorias').style.display='block';
            document.getElementById('listaCategorias').innerHTML=d.categorias.map((c,i)=>`<div class="form-check mb-1"><input type="checkbox" class="form-check-input cat-checkbox" value="${c}" id="c${i}" checked><label class="form-check-label text-light small" for="c${i}">${c}</label></div>`).join('');
            if(d.bouquets && d.bouquets.length > 0){
                document.getElementById('listaBouquets').innerHTML=d.bouquets.map(b=>`<div class="form-check mb-1"><input type="checkbox" class="form-check-input bq-checkbox" value="${b.id}" id="b${b.id}"><label class="text-warning fw-bold small" for="b${b.id}">${b.name}</label></div>`).join('');
            } else {
                document.getElementById('listaBouquets').innerHTML='<p class="text-muted small">Nenhum pacote encontrado no banco de dados do seu IPTV.</p>';
            }
            document.getElementById('btnAnalisar').style.display='none';
        } else alert(d.msg);
    });
}

function iniciarImportacaoReal() {
    const c=Array.from(document.querySelectorAll('.cat-checkbox:checked')).map(x=>x.value);
    const b=Array.from(document.querySelectorAll('.bq-checkbox:checked')).map(x=>x.value);
    if(!c.length) return alert("Selecione categorias!");
    document.getElementById('areaConfig').style.display='none'; document.getElementById('areaProgresso').style.display='block';
    fetch('/iniciar_importacao',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({categorias:c, bouquets:b})}).then(r=>r.json()).then(d=>{currentJobId=d.job_id; monitorInterval=setInterval(verificarStatus, 1000);});
}

function controleJob(a) { fetch(`/controle_job/${currentJobId}/${a}`,{method:'POST'}); }

function verificarStatus() {
    fetch('/status_importacao/'+currentJobId).then(r=>r.json()).then(d=>{
        if(d.status==='nao_encontrado')return;
        document.getElementById('barraProgresso').style.width=d.progress+'%';
        document.getElementById('txtPorcentagem').innerText=d.progress+'%';
        document.getElementById('txtProgresso').innerText=`Inseridos: ${d.atual} de ${d.total}`;
        document.getElementById('txtIgnorados').innerText=`${d.ignorados} Pulados`;
        document.getElementById('countCanais').innerText = d.count_canais || 0;
        document.getElementById('countFilmes').innerText = d.count_filmes || 0;
        document.getElementById('countSeries').innerText = d.count_series || 0;
        const term=document.getElementById('logTerminal'); term.innerHTML=d.logs.join('<br>'); term.scrollTop=term.scrollHeight;
        if(['concluido','erro','cancelado'].includes(d.status)){
            clearInterval(monitorInterval); document.getElementById('areaControles').style.display='none'; document.getElementById('btnNova').style.display='block'; document.getElementById('textStatus').innerText = 'Finalizado!';
            fetch('/gerar_relatorio/'+currentJobId).then(r=>r.json()).then(res=>{
                if(res.texto) {
                    document.getElementById('textoRelatorio').value = res.texto;
                    document.getElementById('areaRelatorio').style.display = 'block';
                }
            });
        }
    });
}

function copiarRelatorio() {
    document.getElementById("textoRelatorio").select();
    document.execCommand("copy");
    alert("Copiado com Sucesso!");
}

function enviarRelatorioZap() {
    let msg = encodeURIComponent(document.getElementById("textoRelatorio").value);
    window.open(`https://api.whatsapp.com/send?text=${msg}`, '_blank');
}
</script>
{% endblock %}
EOF

cat << 'EOF' > "$DIR/templates/loja.html"
<!DOCTYPE html>
<html lang="pt-PT">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Loja - Sync Vods</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        body { background-color: #1a1d20; color: #f8f9fa; font-family: 'Segoe UI', sans-serif; }
        .text-dark-custom { color: #1e1e1e !important; font-weight: 800; }
        .text-black-custom { color: #000 !important; font-weight: 700; }
        .alert-custom { background-color: #f8d7da; color: #842029; border: 2px solid #f5c2c7; font-weight: 700; font-size: 1.1rem;}
        .card-shadow { box-shadow: 0 10px 30px rgba(0,0,0,0.5); }
    </style>
</head>
<body>
<div class="container py-5">
    {% with messages = get_flashed_messages(with_categories=true) %}{% if messages %}{% for category, message in messages %}
    <div class="alert alert-{{ category }} alert-dismissible fade show text-center fs-5 fw-bold mt-3" role="alert">{{ message }}<button type="button" class="btn-close" data-bs-dismiss="alert"></button></div>
    {% endfor %}{% endif %}{% endwith %}

    <div class="row justify-content-center mb-5 mt-2">
        <div class="col-md-8 text-center bg-white p-4 rounded card-shadow">
            <h2 class="text-primary fw-bold mb-3">SyncVods</h2>
            <p class="text-black-custom fs-5 mb-4">Este script permite-lhe registar dados de uma linha M3U num servidor à sua escolha.</p>
            <div class="alert alert-custom p-4 rounded mb-4">
                Entre em contacto com a nossa equipa para saber se este script lhe é útil. Caso compre e não sirva, iremos descontar R$5 do reembolso caso tenha comprado sem ler aqui.
            </div>
            <p class="text-dark-custom fs-5 mb-0 p-3 bg-light rounded border">Sistemas suportados XTREAM UI e XUI (ONE)</p>
        </div>
    </div>

    <div class="row justify-content-center">
        {% for plano in planos %}
        <div class="col-md-5 mb-4">
            <div class="card bg-white card-shadow h-100 border-0">
                <div class="card-header text-center fw-bold fs-4 text-white py-3" style="background-color: {% if plano.category == 'Mensal' %}#198754{% else %}#f8f9fa; color: #212529 !important; border-bottom: 2px solid #ddd;{% endif %};">
                    {{ plano.name }}
                </div>
                <div class="card-body text-center p-4">
                    <h1 class="text-dark-custom fw-bold mb-4">R${{ "%.0f"|format(plano.price) }}</h1>
                    {% if plano.category == 'Mensal' %}
                        <button class="btn btn-success w-100 py-3 mb-4 fs-5 fw-bold shadow" onclick="abrirCheckout('{{ plano.id }}', '{{ plano.name }}')">Assinar por {{ plano.days }} dias</button>
                        <p class="text-black-custom border p-3 rounded" style="background-color: #f1f2f6;">Sincronização ilimitada e automática para 1 servidor.</p>
                    {% else %}
                        <button class="btn btn-outline-dark w-100 py-3 mb-4 fs-5 fw-bold shadow-sm" onclick="abrirCheckout('{{ plano.id }}', '{{ plano.name }}')">Comprar 1 Sincronia</button>
                        <div class="p-4 rounded" style="background-color: #fff3cd; color: #664d03; border: 2px solid #ffecb5; font-size: 1rem;">
                            <p class="mb-3 fw-bold">Esta opção permite-lhe sincronizar 1 vez para 1 servidor por 24 horas.</p>
                            <p class="mb-0 fw-bold">Depois de 24 horas precisará de comprar outra sincronia caso queira usar novamente o script.</p>
                        </div>
                    {% endif %}
                </div>
            </div>
        </div>
        {% endfor %}
    </div>
</div>

<div class="modal fade" id="modalCheckout" tabindex="-1">
  <div class="modal-dialog modal-dialog-centered">
    <div class="modal-content text-dark">
      <div class="modal-header border-bottom-0">
        <h5 class="modal-title fw-bold text-primary">Criar Acesso - <span id="nomePlanoModal"></span></h5>
        <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
      </div>
      <form id="formCheckout" method="POST" action="">
        <div class="modal-body py-0">
          <p class="small text-muted mb-3">Preencha os dados abaixo. Após o pagamento ser aprovado, o sistema liberta o login automaticamente!</p>
          <div class="mb-2">
            <label class="form-label fw-bold small">Nome de Utilizador</label>
            <input type="text" name="username" class="form-control bg-light" required placeholder="Ex: joao123">
          </div>
          <div class="mb-2">
            <label class="form-label fw-bold small">Palavra-passe</label>
            <input type="password" name="password" class="form-control bg-light" required placeholder="Crie a sua palavra-passe">
          </div>
          <div class="mb-2">
            <label class="form-label fw-bold small">WhatsApp</label>
            <input type="text" name="whatsapp" class="form-control bg-light" required placeholder="Ex: 5511999999999">
          </div>
          <div class="mb-3">
            <label class="form-label fw-bold small text-danger">CPF (Apenas Números)</label>
            <input type="text" name="cpf" class="form-control bg-light border-danger" required placeholder="Ex: 12345678900">
          </div>
          <div class="mb-4">
            <label class="form-label fw-bold small text-primary">Forma de Pagamento</label>
            <select name="gateway" class="form-select bg-light border-primary" required>
                {% if settings and settings.mp_access_token %}<option value="mp">Mercado Pago (PIX / Cartão)</option>{% endif %}
                {% if settings and settings.asaas_api_key %}<option value="asaas">Asaas (PIX / Cartão / Boleto)</option>{% endif %}
                {% if not (settings and settings.mp_access_token) and not (settings and settings.asaas_api_key) %}<option value="">Sem Gateway Configurado!</option>{% endif %}
            </select>
          </div>
        </div>
        <div class="modal-footer border-top-0">
          <button type="submit" class="btn btn-success w-100 fw-bold py-2 fs-5">Pagar & Ativar Conta</button>
        </div>
      </form>
    </div>
  </div>
</div>

<footer class="text-center py-4 text-secondary mt-5"><small>Sync Vods &copy; 2026 - O melhor importador cloud do mercado.</small></footer>
<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/js/bootstrap.bundle.min.js"></script>
<script>
    function abrirCheckout(planId, planName) {
        document.getElementById('nomePlanoModal').innerText = planName;
        document.getElementById('formCheckout').action = '/checkout/' + planId;
        new bootstrap.Modal(document.getElementById('modalCheckout')).show();
    }
</script>
</body>
</html>
EOF

echo "[6/7] Validando código Python..."
"$DIR/venv/bin/python" -m py_compile "$DIR/app.py"

echo "[7/7] Configurando serviço systemd e firewall na porta 3000..."
cat << 'EOF' > /etc/systemd/system/xtream_importer.service
[Unit]
Description=Sync Vods Master Panel
After=network.target

[Service]
User=root
WorkingDirectory=/opt/xtream_importer
Environment="TZ=America/Sao_Paulo"
ExecStart=/opt/xtream_importer/venv/bin/gunicorn --workers 1 --threads 8 --timeout 120 --bind 0.0.0.0:3000 app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

ufw allow 3000/tcp > /dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable xtream_importer > /dev/null 2>&1
systemctl restart xtream_importer
sleep 2

IP=$(curl -s --max-time 3 https://api.ipify.org || hostname -I | awk '{print $1}')
echo "============================================================"
echo " ✅ INSTALAÇÃO COMPLETA - SYNC VODS V47.5 UNIVERSAL GOLD"
echo "------------------------------------------------------------"
echo " 🌐 Loja:   http://${IP}:3000/"
echo " 🔐 Login:  http://${IP}:3000/login"
echo " 👑 Admin:  admin / admin123"
echo " 🕒 Hora:   $(date '+%d/%m/%Y %H:%M:%S %Z')"
echo " ⚙️ Status: $(systemctl is-active xtream_importer)"
echo "============================================================"