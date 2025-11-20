#!/bin/bash
set -e
echo "========================================="
echo "   Faka Pro+ Full Stack 一键部署脚本"
echo "   后台JWT登录 + 拖拽UI模块 + 实时预览"
echo "   Debian系统适配"
echo "========================================="

DOMAIN=$1
if [ -z "$DOMAIN" ]; then
  echo "用法: ./deploy_faka_pro_ui_drag_preview.sh yourdomain.com"
  exit 1
fi

APP_DIR="/var/www/faka-pro-ui"
mkdir -p $APP_DIR
cd $APP_DIR

echo ">>> 更新系统并安装依赖"
apt update
apt install -y docker.io docker-compose certbot unzip curl git build-essential

mkdir -p app public admin docker app/payment uploads/banner backup

# =========================
# 1. 后端 package.json
# =========================
cat > app/package.json <<'EOF'
{
  "name": "faka-pro-ui-drag-preview",
  "version": "1.0.0",
  "main": "server.js",
  "dependencies": {
    "express": "^4.19.2",
    "better-sqlite3": "^9.4.0",
    "bcryptjs": "^2.4.3",
    "jsonwebtoken": "^9.0.2",
    "cors": "^2.8.5",
    "axios": "^1.6.7",
    "stripe": "^14.0.0",
    "nodemailer": "^6.9.3",
    "multer": "^1.4.5"
  }
}
EOF

# =========================
# 2. 后端 server.js（含拖拽模块+实时预览）
# =========================
cat > app/server.js <<'EOF'
const express = require("express");
const cors = require("cors");
const db = require("better-sqlite3")("data.db");
const multer = require("multer");
const fs = require("fs");
const crypto = require("crypto");
const stripePay = require("./payment/stripe");
const paypalPay = require("./payment/paypal");
const mailer = require("./mail");
const setupDB = require("./setup-db");
const jwt = require("jsonwebtoken");
const bcrypt = require("bcryptjs");

setupDB(db);
const app = express();
app.use(cors());
app.use(express.json());
app.use("/public", express.static("../public"));
app.use("/admin", express.static("../admin"));

// ---------------- JWT 登录 ----------------
const ADMIN_USER = process.env.ADMIN_USER || "admin";
const ADMIN_PASS = process.env.ADMIN_PASS || "123456";
const JWT_SECRET = process.env.JWT_SECRET || "faka_pro_jwt_secret";

app.post("/api/admin/login",(req,res)=>{
  const {username,password}=req.body;
  if(username===ADMIN_USER && bcrypt.compareSync(password,bcrypt.hashSync(ADMIN_PASS,10))){
    const token=jwt.sign({username},JWT_SECRET,{expiresIn:"12h"});
    res.json({success:true,token});
  }else res.json({success:false,msg:"用户名或密码错误"});
});

function verifyToken(req,res,next){
  const authHeader=req.headers["authorization"];
  if(!authHeader) return res.status(401).json({success:false,msg:"缺少 token"});
  const token=authHeader.split(" ")[1];
  jwt.verify(token,JWT_SECRET,(err,decoded)=>{
    if(err) return res.status(401).json({success:false,msg:"无效 token"});
    req.user=decoded;
    next();
  });
}

// ---------------- AES 卡密 ----------------
const AES_KEY = process.env.AES_KEY || "12345678901234567890123456789012"; 
function encrypt(text){
  const iv=crypto.randomBytes(16);
  const cipher=crypto.createCipheriv("aes-256-cbc",Buffer.from(AES_KEY),iv);
  let encrypted=cipher.update(text);
  encrypted=Buffer.concat([encrypted,cipher.final()]);
  return iv.toString("hex")+":"+encrypted.toString("hex");
}
function decrypt(data){
  const parts=data.split(":");
  const iv=Buffer.from(parts[0],'hex');
  const encrypted=Buffer.from(parts[1],'hex');
  const decipher=crypto.createDecipheriv("aes-256-cbc",Buffer.from(AES_KEY),iv);
  let decrypted=decipher.update(encrypted);
  decrypted=Buffer.concat([decrypted,decipher.final()]);
  return decrypted.toString();
}

// ---------------- UI模块表 ----------------
db.prepare(`CREATE TABLE IF NOT EXISTS ui_modules (
  id INTEGER PRIMARY KEY,
  type TEXT,
  data TEXT,
  display INTEGER,
  sort_order INTEGER
)`).run();

// ---------------- API: UI模块管理 ----------------
app.get("/api/admin/ui-modules", verifyToken, (req,res)=>{
  const modules=db.prepare("SELECT * FROM ui_modules ORDER BY sort_order ASC").all();
  modules.forEach(m=>{try{m.data=JSON.parse(m.data)}catch{}});
  res.json({success:true,modules});
});

app.post("/api/admin/ui-modules/add", verifyToken, (req,res)=>{
  const {type,data,display}=req.body;
  const maxOrder=db.prepare("SELECT MAX(sort_order) as m FROM ui_modules").get().m||0;
  db.prepare("INSERT INTO ui_modules(type,data,display,sort_order) VALUES(?,?,?,?)")
    .run(type,JSON.stringify(data),display?1:0,maxOrder+1);
  res.json({success:true});
});

app.post("/api/admin/ui-modules/update", verifyToken, (req,res)=>{
  const {id,data,display}=req.body;
  db.prepare("UPDATE ui_modules SET data=?,display=? WHERE id=?").run(JSON.stringify(data),display?1:0,id);
  res.json({success:true});
});

app.post("/api/admin/ui-modules/sort", verifyToken, (req,res)=>{
  const {sortedIds}=req.body;
  const stmt=db.prepare("UPDATE ui_modules SET sort_order=? WHERE id=?");
  const tx=db.transaction(()=>{
    sortedIds.forEach((id,index)=>stmt.run(index,id));
  });
  tx();
  res.json({success:true});
});

// ---------------- Banner上传 ----------------
const bannerUpload=multer({dest:"uploads/banner/"});
app.post("/api/admin/banner/upload",verifyToken,bannerUpload.single("file"),(req,res)=>{
  try{if(!req.file) return res.json({success:false,msg:"未上传文件"});
  fs.renameSync(req.file.path,"public/banner.jpg");res.json({success:true,url:"/banner.jpg"});}catch(e){res.json({success:false,msg:e.message)}}
});

// ---------------- 前端实时渲染模块 ----------------
app.get("/api/ui-modules-public",(req,res)=>{
  const modules=db.prepare("SELECT * FROM ui_modules WHERE display=1 ORDER BY sort_order ASC").all();
  modules.forEach(m=>{try{m.data=JSON.parse(m.data)}catch{}});
  res.json({success:true,modules});
});

// ---------------- 商品/SKU/卡密/订单接口 (JWT保护) ----------------
// 可复用之前 Faka Pro+ 脚本的接口（略）

app.listen(3000,()=>console.log("Faka Pro+ UI拖拽+实时预览后端启动 on 3000"));
EOF

# =========================
# 3. setup-db.js 初始化（含默认模块）
# =========================
cat > app/setup-db.js <<'EOF'
module.exports=(db)=>{
db.prepare(`CREATE TABLE IF NOT EXISTS product_group(id INTEGER PRIMARY KEY,name TEXT)`).run();
db.prepare(`CREATE TABLE IF NOT EXISTS product(id INTEGER PRIMARY KEY,group_id INTEGER,name TEXT,desc TEXT)`).run();
db.prepare(`CREATE TABLE IF NOT EXISTS product_sku(id INTEGER PRIMARY KEY,product_id INTEGER,title TEXT,price REAL)`).run();
db.prepare(`CREATE TABLE IF NOT EXISTS card(id INTEGER PRIMARY KEY,product_id INTEGER,code TEXT,used INTEGER)`).run();
db.prepare(`CREATE TABLE IF NOT EXISTS orders(id INTEGER PRIMARY KEY,product_id INTEGER,sku_id INTEGER,card INTEGER,email TEXT)`).run();

const count=db.prepare("SELECT COUNT(*) as c FROM product").get().c;
if(count===0){
  db.prepare("INSERT INTO product_group(name) VALUES('海外账号')").run();
  db.prepare("INSERT INTO product(group_id,name,desc) VALUES(1,'示例商品','自动发货商品')").run();
  db.prepare("INSERT INTO product_sku(product_id,title,price) VALUES(1,'基础版',5)").run();
  db.prepare("INSERT INTO product_sku(product_id,title,price) VALUES(1,'高级版',9)").run();
}

// 默认模块
const defaultModules=[
  ["banner",{url:"/public/banner.jpg"},1,0],
  ["text",{text:"欢迎来到海外账号商城！"},1,1],
  ["products",{title:"热门商品"},1,2]
];
defaultModules.forEach(([type,data,display,order])=>{
  const exists=db.prepare("SELECT * FROM ui_modules WHERE sort_order=?").get(order);
  if(!exists) db.prepare("INSERT INTO ui_modules(type,data,display,sort_order) VALUES(?,?,?,?)")
    .run(type,JSON.stringify(data),display,order);
});
};
EOF

# =========================
# 4. 前端首页 public/index.html 渲染模块
# =========================
mkdir -p public
cat > public/index.html <<'EOF'
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"><title>Faka Pro+ 商城</title>
<script src="https://unpkg.com/axios/dist/axios.min.js"></script>
</head>
<body>
<div id="home-modules"></div>
<script>
axios.get("/api/ui-modules-public").then(r=>{
  if(r.data.success){
    const modules=r.data.modules;
    const container=document.getElementById("home-modules");
    modules.forEach(m=>{
      let el=document.createElement("div");
      if(m.type==="text") el.innerText=m.data.text;
      if(m.type==="banner") el.innerHTML='<img src="'+m.data.url+'" style="width:400px">';
      if(m.type==="products") el.innerHTML='<h2>'+m.data.title+'</h2>';
      container.appendChild(el);
    });
  }
});
</script>
</body>
</html>
EOF

# =========================
# 5. admin 面板可视化拖拽 + 实时预览
# =========================
mkdir -p admin
cat > admin/index.html <<'EOF'
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>后台管理 - Faka Pro+</title>
<script src="https://unpkg.com/axios/dist/axios.min.js"></script>
<script src="https://unpkg.com/vue@3/dist/vue.global.prod.js"></script>
<script src="https://unpkg.com/vuedraggable@4.1.0/dist/vuedraggable.umd.min.js"></script>
<link href="https://cdn.jsdelivr.net/npm/tailwindcss@2.2.19/dist/tailwind.min.css" rel="stylesheet">
</head>
<body>
<div id="app" class="p-4" v-cloak>
<h1 class="text-2xl font-bold mb-4">Faka Pro+ 后台</h1>

<div v-if="!token">
  <input v-model="username" placeholder="用户名" class="border p-1 mr-2">
  <input type="password" v-model="password" placeholder="密码" class="border p-1 mr-2">
  <button @click="login" class="bg-blue-600 text-white px-3 py-1 rounded">登录</button>
</div>

<div v-else>
  <h2 class="text-xl font-bold mb-4">首页模块管理 (拖拽 + 实时预览)</h2>
  <div class="flex">
    <!-- 左侧模块列表 -->
    <div class="w-1/2 pr-4">
      <draggable v-model="modules" item-key="id" @end="saveSort">
        <template #item="{element}">
          <div class="border p-2 mb-2 bg-gray-100 flex justify-between">
            <span>{{element.type}} - {{element.data.text || element.data.title || element.data.url}}</span>
            <div>
              <input type="checkbox" v-model="element.display"> 显示
              <button @click="editModule(element)" class="bg-yellow-500 text-white px-1 py-0.5 rounded">编辑</button>
              <button @click="deleteModule(element.id)" class="bg-red-500 text-white px-1 py-0.5 rounded">删除</button>
            </div>
          </div>
        </template>
      </draggable>
      <button @click="addModule" class="bg-green-500 text-white px-3 py-1 rounded mt-2">新增模块</button>
    </div>

    <!-- 右侧实时预览 -->
    <div class="w-1/2 border p-2 bg-white">
      <h3 class="font-bold mb-2">实时预览</h3>
      <div id="preview-area">
        <div v-for="m in modules" v-if="m.display" :key="m.id" class="border mb-2 p-2">
          <div v-if="m.type==='text'">{{m.data.text}}</div>
          <div v-if="m.type==='banner'"><img :src="m.data.url" style="width:100%"></div>
          <div v-if="m.type==='products'"><h4>{{m.data.title}}</h4></div>
        </div>
      </div>
    </div>
  </div>
</div>
</div>

<script>
const { createApp } = Vue;
const { draggable } = window["vuedraggable"];
createApp({
data(){return{
  username:'', password:'', token:'', modules:[]
}},
mounted(){},
methods:{
login(){
  axios.post("/api/admin/login",{username:this.username,password:this.password}).then(r=>{
    if(r.data.success){this.token=r.data.token; this.fetchModules();}
    else alert(r.data.msg);
  });
},
fetchModules(){
  axios.get("/api/admin/ui-modules",{headers:{Authorization:"Bearer "+this.token}})
    .then(r=>{if(r.data.success)this.modules=r.data.modules;});
},
saveSort(){
  const sortedIds=this.modules.map(m=>m.id);
  axios.post("/api/admin/ui-modules/sort",{sortedIds},{headers:{Authorization:"Bearer "+this.token}});
},
addModule(){
  const type=prompt("模块类型 banner/products/text"); if(!type)return;
  const data={};
  if(type==='text') data.text=prompt("文本内容");
  if(type==='products') data.title=prompt("模块标题");
  if(type==='banner') data.url=prompt("图片URL");
  axios.post("/api/admin/ui-modules/add",{type,data,display:1},{headers:{Authorization:"Bearer "+this.token}})
    .then(r=>{if(r.data.success)this.fetchModules();});
},
editModule(mod){
  if(mod.type==='text') mod.data.text=prompt("修改文本",mod.data.text);
  if(mod.type==='products') mod.data.title=prompt("修改标题",mod.data.title);
  if(mod.type==='banner') mod.data.url=prompt("修改图片URL",mod.data.url);
  axios.post("/api/admin/ui-modules/update",{id:mod.id,data:mod.data,display:mod.display},{headers:{Authorization:"Bearer "+this.token}});
},
deleteModule(id){
  if(!confirm("确认删除?")) return;
  axios.post("/api/admin/ui-modules/update",{id,data:{},display:0},{headers:{Authorization:"Bearer "+this.token}})
    .then(r=>{if(r.data.success)this.fetchModules();});
}
}
}).component('draggable', draggable).mount('#app');
</script>
</body>
</html>
EOF

# =========================
# 6. Dockerfile + docker-compose + Nginx + Certbot
# ==========================
cat > docker/Dockerfile <<EOF
FROM node:18
WORKDIR /app
COPY ../app /app
RUN npm install
CMD ["node","server.js"]
EOF

cat > docker/nginx.conf <<EOF
server { listen 80; server_name $DOMAIN; return 301 https://$DOMAIN\$request_uri; }
server { listen 443 ssl; server_name $DOMAIN; ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem; ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
location / { proxy_pass http://app:3000; proxy_set_header Host \$host; } }
EOF

cat > docker-compose.yml <<EOF
version: "3"
services:
  app:
    build: ./docker
    container_name: faka-app
    volumes:
      - ./app:/app
      - ./public:/public
      - ./admin:/admin
      - ./uploads:/uploads
      - ./backup:/backup
    restart: always
  nginx:
    image: nginx
    container_name: faka-nginx
    volumes:
      - ./docker/nginx.conf:/etc/nginx/conf.d/default.conf
      - /etc/letsencrypt:/etc/letsencrypt
      - ./public:/usr/share/nginx/html
    ports:
      - "80:80"
      - "443:443"
    depends_on:
      - app
EOF

# =========================
# 7. HTTPS
# ==========================
certbot certonly --standalone -d $DOMAIN --agree-tos -m admin@$DOMAIN --non-interactive

# =========================
# 8. 启动服务
# ==========================
docker-compose down
docker-compose up -d

echo "=========================="
echo "Faka Pro+ UI拖拽 + 实时预览部署完成！"
echo "后台默认账号: admin / 123456 (请部署后立即修改环境变量)"
echo "前台访问: https://$DOMAIN"
echo "后台访问: https://$DOMAIN/admin"
echo "=========================="
