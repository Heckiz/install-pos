#!/bin/bash

# Script de instalación para POS optimizado para Raspberry Pi 3
echo "=== Iniciando instalación del Sistema POS ==="

# Crear estructura de directorios
echo "Creando estructura de directorios..."
mkdir -p ~/pos-system/data
mkdir -p ~/pos-system/public/images
mkdir -p ~/pos-system/public/css
mkdir -p ~/pos-system/public/js
mkdir -p ~/pos-system/server

# Instalar dependencias del sistema
echo "Instalando dependencias del sistema..."
sudo apt update
sudo apt install -y nodejs npm sqlite3 cups build-essential libcups2-dev

# Configurar CUPS para la impresora
echo "Configurando CUPS..."
sudo usermod -a -G lpadmin pi
sudo cupsctl --remote-any
sudo systemctl restart cups

# Crear package.json optimizado
cat > ~/pos-system/package.json << 'EOL'
{
  "name": "pos-system",
  "version": "1.0.0",
  "description": "Sistema POS optimizado para Raspberry Pi 3",
  "main": "server/index.js",
  "scripts": {
    "start": "node server/index.js"
  },
  "dependencies": {
    "express": "4.18.2",
    "better-sqlite3": "7.6.2",
    "body-parser": "1.20.1",
    "cors": "2.8.5",
    "escpos": "3.0.0-alpha.6",
    "escpos-usb": "3.0.0-alpha.4",
    "socket.io": "4.5.4"
  }
}
EOL

# Instalar dependencias de Node.js
echo "Instalando dependencias de Node.js..."
cd ~/pos-system
npm install --legacy-peer-deps

# Crear archivo de base de datos SQLite
echo "Creando base de datos SQLite..."
cat > ~/pos-system/server/db.js << 'EOL'
const Database = require('better-sqlite3');
const path = require('path');
const fs = require('fs');

// Asegurar que el directorio data existe
const dataDir = path.join(__dirname, '../data');
if (!fs.existsSync(dataDir)) {
  fs.mkdirSync(dataDir, { recursive: true });
}

const dbPath = path.join(dataDir, 'pos.db');
const db = new Database(dbPath);

// Inicializar la base de datos
function initDb() {
  // Crear tablas
  db.exec(`
    -- Crear tabla de categorías
    CREATE TABLE IF NOT EXISTS categories (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      color TEXT
    );

    -- Crear tabla de productos
    CREATE TABLE IF NOT EXISTS products (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      price REAL NOT NULL,
      barcode TEXT,
      stock INTEGER DEFAULT 0,
      category_id TEXT,
      image TEXT,
      cost REAL DEFAULT 0,
      FOREIGN KEY (category_id) REFERENCES categories(id)
    );

    -- Crear tabla de ventas
    CREATE TABLE IF NOT EXISTS sales (
      id TEXT PRIMARY KEY,
      date TEXT NOT NULL,
      total REAL NOT NULL,
      payment_method TEXT NOT NULL,
      amount_paid REAL,
      change_amount REAL,
      cashier TEXT
    );

    -- Crear tabla de items de venta
    CREATE TABLE IF NOT EXISTS sale_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sale_id TEXT NOT NULL,
      product_id TEXT NOT NULL,
      quantity INTEGER NOT NULL,
      price REAL NOT NULL,
      total REAL NOT NULL,
      FOREIGN KEY (sale_id) REFERENCES sales(id),
      FOREIGN KEY (product_id) REFERENCES products(id)
    );

    -- Crear tabla de caja registradora
    CREATE TABLE IF NOT EXISTS cash_registers (
      id TEXT PRIMARY KEY,
      open_date TEXT NOT NULL,
      close_date TEXT,
      initial_amount REAL NOT NULL,
      final_amount REAL,
      expected_amount REAL,
      status TEXT NOT NULL,
      opened_by TEXT,
      closed_by TEXT,
      notes TEXT
    );

    -- Crear tabla de movimientos de caja
    CREATE TABLE IF NOT EXISTS cash_movements (
      id TEXT PRIMARY KEY,
      register_id TEXT NOT NULL,
      date TEXT NOT NULL,
      type TEXT NOT NULL,
      amount REAL NOT NULL,
      reason TEXT,
      user_id TEXT,
      FOREIGN KEY (register_id) REFERENCES cash_registers(id)
    );
  `);

  // Verificar si hay datos
  const productCount = db.prepare('SELECT COUNT(*) as count FROM products').get();
  
  if (productCount.count === 0) {
    // Insertar datos de ejemplo
    db.exec(`
      -- Insertar categorías de ejemplo
      INSERT INTO categories (id, name, color) VALUES 
      ('cat-1', 'Bebidas', '#3498db'),
      ('cat-2', 'Alimentos', '#2ecc71'),
      ('cat-3', 'Limpieza', '#9b59b6');

      -- Insertar productos de ejemplo
      INSERT INTO products (id, name, price, barcode, stock, category_id, cost) VALUES 
      ('prod-1', 'Agua Mineral 500ml', 15.00, '7501234567890', 50, 'cat-1', 10.00),
      ('prod-2', 'Refresco Cola 600ml', 18.50, '7509876543210', 40, 'cat-1', 12.00),
      ('prod-3', 'Pan Blanco', 35.00, '7507894561230', 20, 'cat-2', 25.00),
      ('prod-4', 'Jabón Líquido', 45.00, '7503216549870', 15, 'cat-3', 30.00);
    `);
  }
}

// Inicializar la base de datos
initDb();

module.exports = db;
EOL

# Crear servicio de impresión
cat > ~/pos-system/server/printer.js << 'EOL'
const escpos = require('escpos');
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');

// Configuración de la impresora
const printerConfig = {
  name: 'POS_Printer',
  type: 'epson',
  width: 42, // Caracteres por línea para impresora de 58mm
  store: {
    name: 'Mi Tienda',
    address: 'Calle Principal 123',
    phone: '123-456-7890'
  }
};

// Función para imprimir ticket
function printReceipt(data) {
  return new Promise((resolve) => {
    try {
      // Generar contenido del ticket
      const content = generateReceiptContent(data);
      
      // Guardar en archivo temporal
      const tempFile = path.join(__dirname, '../data', `ticket-${Date.now()}.txt`);
      fs.writeFileSync(tempFile, content);
      
      // Imprimir usando lp (CUPS)
      exec(`lp -d ${printerConfig.name} ${tempFile}`, (error) => {
        if (error) {
          console.error('Error al imprimir:', error);
        } else {
          console.log('Ticket enviado a la impresora');
        }
        
        // Eliminar archivo temporal después de un tiempo
        setTimeout(() => {
          fs.unlink(tempFile, () => {});
        }, 1000);
        
        resolve(true);
      });
    } catch (error) {
      console.error('Error en impresión:', error);
      resolve(false);
    }
  });
}

// Generar contenido del ticket
function generateReceiptContent(data) {
  const { store } = printerConfig;
  const { sale, items } = data;
  
  // Formatear fecha
  const date = new Date(sale.date);
  const formattedDate = `${date.getDate()}/${date.getMonth() + 1}/${date.getFullYear()} ${date.getHours()}:${date.getMinutes()}`;
  
  // Cabecera
  let content = `
${store.name}
${store.address}
${store.phone}

Fecha: ${formattedDate}
Ticket: #${sale.id.slice(-6)}
Cajero: ${sale.cashier || 'Cajero'}

--------------------------------
PRODUCTO                  TOTAL
--------------------------------
`;

  // Productos
  items.forEach(item => {
    const name = item.name.padEnd(20).substring(0, 20);
    const total = item.total.toFixed(2).padStart(10);
    content += `${name} ${total}\n`;
    content += `  ${item.quantity} x ${item.price.toFixed(2)}\n`;
  });

  // Total y forma de pago
  content += `
--------------------------------
TOTAL:                 $${sale.total.toFixed(2)}
--------------------------------

Método de pago: ${sale.payment_method === 'cash' ? 'Efectivo' : 'Tarjeta'}
`;

  // Si es efectivo, mostrar cambio
  if (sale.payment_method === 'cash' && sale.amount_paid) {
    content += `
Recibido: $${sale.amount_paid.toFixed(2)}
Cambio:   $${sale.change_amount.toFixed(2)}
`;
  }

  // Pie de página
  content += `

¡Gracias por su compra!
`;

  return content;
}

module.exports = {
  printReceipt
};
EOL

# Crear servidor Express
cat > ~/pos-system/server/index.js << 'EOL'
const express = require('express');
const bodyParser = require('body-parser');
const cors = require('cors');
const path = require('path');
const http = require('http');
const socketIo = require('socket.io');
const { v4: uuidv4 } = require('uuid');

// Importar módulos
const db = require('./db');
const { printReceipt } = require('./printer');

// Configuración
const app = express();
const server = http.createServer(app);
const io = socketIo(server);
const port = 3000;

// Middleware
app.use(cors());
app.use(bodyParser.json());
app.use(express.static(path.join(__dirname, '../public')));

// Websocket para actualizaciones en tiempo real
io.on('connection', (socket) => {
  console.log('Cliente conectado');
  
  socket.on('disconnect', () => {
    console.log('Cliente desconectado');
  });
});

// API Routes - Productos
app.get('/api/products', (req, res) => {
  try {
    const products = db.prepare('SELECT * FROM products').all();
    res.json(products);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.get('/api/products/:id', (req, res) => {
  try {
    const product = db.prepare('SELECT * FROM products WHERE id = ?').get(req.params.id);
    if (!product) {
      return res.status(404).json({ error: 'Producto no encontrado' });
    }
    res.json(product);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.post('/api/products', (req, res) => {
  try {
    const { name, price, barcode, stock, category_id, image, cost } = req.body;
    const id = uuidv4();
    
    db.prepare(
      'INSERT INTO products (id, name, price, barcode, stock, category_id, image, cost) VALUES (?, ?, ?, ?, ?, ?, ?, ?)'
    ).run(id, name, price, barcode, stock || 0, category_id, image, cost || 0);
    
    res.status(201).json({ id, ...req.body });
    
    // Notificar a los clientes
    io.emit('product-updated');
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// API Routes - Categorías
app.get('/api/categories', (req, res) => {
  try {
    const categories = db.prepare('SELECT * FROM categories').all();
    res.json(categories);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// API Routes - Ventas
app.post('/api/sales', (req, res) => {
  try {
    const { date, total, payment_method, amount_paid, change_amount, items, cashier } = req.body;
    const id = uuidv4();
    
    // Iniciar transacción
    db.prepare('BEGIN TRANSACTION').run();
    
    // Insertar venta
    db.prepare(
      'INSERT INTO sales (id, date, total, payment_method, amount_paid, change_amount, cashier) VALUES (?, ?, ?, ?, ?, ?, ?)'
    ).run(id, date, total, payment_method, amount_paid, change_amount, cashier);
    
    // Insertar items y actualizar stock
    const insertItem = db.prepare(
      'INSERT INTO sale_items (sale_id, product_id, quantity, price, total) VALUES (?, ?, ?, ?, ?)'
    );
    
    const updateStock = db.prepare(
      'UPDATE products SET stock = stock - ? WHERE id = ?'
    );
    
    items.forEach(item => {
      insertItem.run(id, item.product_id, item.quantity, item.price, item.total);
      updateStock.run(item.quantity, item.product_id);
    });
    
    // Confirmar transacción
    db.prepare('COMMIT').run();
    
    // Responder
    res.status(201).json({ 
      id, 
      date, 
      total, 
      payment_method, 
      amount_paid, 
      change_amount,
      cashier
    });
    
    // Notificar a los clientes
    io.emit('sale-completed');
  } catch (error) {
    // Revertir transacción en caso de error
    db.prepare('ROLLBACK').run();
    res.status(500).json({ error: error.message });
  }
});

// API Routes - Historial de ventas
app.get('/api/sales', (req, res) => {
  try {
    const sales = db.prepare(`
      SELECT s.*, 
        (SELECT COUNT(*) FROM sale_items WHERE sale_id = s.id) as item_count
      FROM sales s
      ORDER BY date DESC
    `).all();
    
    res.json(sales);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.get('/api/sales/:id', (req, res) => {
  try {
    const sale = db.prepare('SELECT * FROM sales WHERE id = ?').get(req.params.id);
    
    if (!sale) {
      return res.status(404).json({ error: 'Venta no encontrada' });
    }
    
    const items = db.prepare(`
      SELECT si.*, p.name 
      FROM sale_items si
      JOIN products p ON si.product_id = p.id
      WHERE si.sale_id = ?
    `).all(req.params.id);
    
    res.json({ sale, items });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// API Routes - Impresión
app.post('/api/print', async (req, res) => {
  try {
    const success = await printReceipt(req.body);
    res.json({ success });
  } catch (error) {
    res.status(500).json({ success: false, error: error.message });
  }
});

// API Routes - Caja
app.get('/api/cash/current', (req, res) => {
  try {
    const register = db.prepare('SELECT * FROM cash_registers WHERE status = "open" ORDER BY open_date DESC LIMIT 1').get();
    
    if (register) {
      // Calcular monto esperado
      const movements = db.prepare('SELECT * FROM cash_movements WHERE register_id = ?').all(register.id);
      
      let expectedAmount = register.initial_amount;
      movements.forEach(movement => {
        if (movement.type === 'add') {
          expectedAmount += movement.amount;
        } else if (movement.type === 'remove') {
          expectedAmount -= movement.amount;
        }
      });
      
      register.expected_amount = expectedAmount;
      register.movements = movements;
    }
    
    res.json(register || null);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.post('/api/cash/open', (req, res) => {
  try {
    const { initial_amount, notes, opened_by } = req.body;
    const id = uuidv4();
    const open_date = new Date().toISOString();
    
    db.prepare(
      'INSERT INTO cash_registers (id, open_date, initial_amount, status, opened_by, notes) VALUES (?, ?, ?, ?, ?, ?)'
    ).run(id, open_date, initial_amount, 'open', opened_by, notes);
    
    const register = db.prepare('SELECT * FROM cash_registers WHERE id = ?').get(id);
    
    res.status(201).json(register);
    
    // Notificar a los clientes
    io.emit('cash-register-updated');
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.post('/api/cash/close', (req, res) => {
  try {
    const { register_id, final_amount, notes, closed_by } = req.body;
    const close_date = new Date().toISOString();
    
    // Obtener registro actual
    const register = db.prepare('SELECT * FROM cash_registers WHERE id = ?').get(register_id);
    
    if (!register) {
      return res.status(404).json({ error: 'Registro de caja no encontrado' });
    }
    
    if (register.status !== 'open') {
      return res.status(400).json({ error: 'La caja ya está cerrada' });
    }
    
    // Calcular monto esperado
    const movements = db.prepare('SELECT * FROM cash_movements WHERE register_id = ?').all(register_id);
    
    let expectedAmount = register.initial_amount;
    movements.forEach(movement => {
      if (movement.type === 'add') {
        expectedAmount += movement.amount;
      } else if (movement.type === 'remove') {
        expectedAmount -= movement.amount;
      }
    });
    
    // Actualizar registro
    db.prepare(
      'UPDATE cash_registers SET close_date = ?, final_amount = ?, expected_amount = ?, status = ?, closed_by = ?, notes = ? WHERE id = ?'
    ).run(close_date, final_amount, expectedAmount, 'closed', closed_by, notes, register_id);
    
    const updatedRegister = db.prepare('SELECT * FROM cash_registers WHERE id = ?').get(register_id);
    
    res.json(updatedRegister);
    
    // Notificar a los clientes
    io.emit('cash-register-updated');
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.post('/api/cash/movement', (req, res) => {
  try {
    const { register_id, type, amount, reason, user_id } = req.body;
    const id = uuidv4();
    const date = new Date().toISOString();
    
    // Verificar que el registro existe y está abierto
    const register = db.prepare('SELECT * FROM cash_registers WHERE id = ? AND status = "open"').get(register_id);
    
    if (!register) {
      return res.status(404).json({ error: 'Registro de caja no encontrado o cerrado' });
    }
    
    // Insertar movimiento
    db.prepare(
      'INSERT INTO cash_movements (id, register_id, date, type, amount, reason, user_id) VALUES (?, ?, ?, ?, ?, ?, ?)'
    ).run(id, register_id, date, type, amount, reason, user_id);
    
    const movement = db.prepare('SELECT * FROM cash_movements WHERE id = ?').get(id);
    
    res.status(201).json(movement);
    
    // Notificar a los clientes
    io.emit('cash-register-updated');
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Ruta para servir la aplicación
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, '../public', 'index.html'));
});

// Iniciar servidor
server.listen(port, () => {
  console.log(`Servidor POS ejecutándose en http://localhost:${port}`);
});
EOL

# Crear archivo HTML principal
cat > ~/pos-system/public/index.html << 'EOL'
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Sistema POS</title>
  <link rel="stylesheet" href="/css/styles.css">
  <link rel="manifest" href="/manifest.json">
</head>
<body>
  <div id="app">
    <header>
      <div class="logo">
        <img src="/images/logo.png" alt="Logo" class="logo-img">
        <h1>AlmacenPOS</h1>
      </div>
      <nav>
        <button class="nav-btn active" data-page="pos">Punto de Venta</button>
        <button class="nav-btn" data-page="products">Productos</button>
        <button class="nav-btn" data-page="sales">Ventas</button>
        <button class="nav-btn" data-page="cash">Caja</button>
      </nav>
      <div class="user-info">
        <span id="cashier-name">Cajero</span>
        <button id="logout-btn">Salir</button>
      </div>
    </header>
    
    <main>
      <!-- Página de POS -->
      <section id="pos-page" class="page active">
        <div class="pos-container">
          <div class="pos-left">
            <div class="search-bar">
              <input type="text" id="barcode-input" placeholder="Escanear código de barras (F9)">
              <button id="search-btn">Buscar</button>
            </div>
            
            <div class="categories">
              <button class="category-btn active" data-category="all">Todos</button>
              <!-- Las categorías se cargarán dinámicamente -->
            </div>
            
            <div class="products-grid" id="products-grid">
              <!-- Los productos se cargarán dinámicamente -->
            </div>
          </div>
          
          <div class="pos-right">
            <div class="cart-header">
              <h2>Carrito</h2>
              <span class="cart-count">0 items</span>
            </div>
            
            <div class="cart-items" id="cart-items">
              <!-- Los items del carrito se mostrarán aquí -->
              <div class="empty-cart">
                <img src="/images/cart.png" alt="Carrito vacío">
                <p>El carrito está vacío</p>
              </div>
            </div>
            
            <div class="cart-footer">
              <div class="cart-total">
                <span>Total:</span>
                <span id="cart-total">$0.00</span>
              </div>
              
              <div class="cart-actions">
                <button id="save-btn" disabled>Guardar (F7)</button>
                <button id="checkout-btn" disabled>Cobrar (F8)</button>
              </div>
            </div>
          </div>
        </div>
      </section>
      
      <!-- Página de Productos -->
      <section id="products-page" class="page">
        <h2>Gestión de Productos</h2>
        <div class="products-actions">
          <button id="add-product-btn">Agregar Producto</button>
          <input type="text" id="product-search" placeholder="Buscar productos...">
        </div>
        
        <table class="products-table">
          <thead>
            <tr>
              <th>Nombre</th>
              <th>Precio</th>
              <th>Stock</th>
              <th>Categoría</th>
              <th>Acciones</th>
            </tr>
          </thead>
          <tbody id="products-table-body">
            <!-- Los productos se cargarán dinámicamente -->
          </tbody>
        </table>
      </section>
      
      <!-- Página de Ventas -->
      <section id="sales-page" class="page">
        <h2>Historial de Ventas</h2>
        <div class="sales-filters">
          <input type="date" id="sales-date-from">
          <input type="date" id="sales-date-to">
          <button id="filter-sales-btn">Filtrar</button>
        </div>
        
        <table class="sales-table">
          <thead>
            <tr>
              <th>Fecha</th>
              <th>Total</th>
              <th>Método de Pago</th>
              <th>Cajero</th>
              <th>Acciones</th>
            </tr>
          </thead>
          <tbody id="sales-table-body">
            <!-- Las ventas se cargarán dinámicamente -->
          </tbody>
        </table>
      </section>
      
      <!-- Página de Caja -->
      <section id="cash-page" class="page">
        <h2>Gestión de Caja</h2>
        
        <div id="cash-register-closed" class="cash-register-status">
          <div class="cash-register-message">
            <img src="/images/cash-register.png" alt="Caja cerrada">
            <h3>No hay caja abierta</h3>
            <p>Abra una caja para comenzar a registrar ventas</p>
            <button id="open-register-btn">Abrir Caja</button>
          </div>
        </div>
        
        <div id="cash-register-open" class="cash-register-status hidden">
          <div class="cash-register-info">
            <h3>Caja Abierta</h3>
            <div class="cash-register-details">
              <div class="cash-detail">
                <span>Monto Inicial:</span>
                <span id="initial-amount">$0.00</span>
              </div>
              <div class="cash-detail">
                <span>Monto Esperado:</span>
                <span id="expected-amount">$0.00</span>
              </div>
              <div class="cash-detail">
                <span>Tiempo Transcurrido:</span>
                <span id="elapsed-time">0h 0m</span>
              </div>
            </div>
            
            <div class="cash-actions">
              <button id="add-cash-btn">Registrar Ingreso</button>
              <button id="remove-cash-btn">Registrar Retiro</button>
              <button id="close-register-btn">Cerrar Caja</button>
            </div>
          </div>
          
          <div class="cash-movements">
            <h3>Movimientos</h3>
            <table class="movements-table">
              <thead>
                <tr>
                  <th>Fecha</th>
                  <th>Tipo</th>
                  <th>Monto</th>
                  <th>Motivo</th>
                </tr>
              </thead>
              <tbody id="movements-table-body">
                <!-- Los movimientos se cargarán dinámicamente -->
              </tbody>
            </table>
          </div>
        </div>
      </section>
    </main>
    
    <!-- Modales -->
    <div id="payment-modal" class="modal">
      <div class="modal-content">
        <div class="modal-header">
          <h2>Procesar Pago</h2>
          <span class="close-modal">&times;</span>
        </div>
        <div class="modal-body">
          <div class="payment-total">
            <span>Total a pagar:</span>
            <span id="payment-total-amount">$0.00</span>
          </div>
          
          <div class="payment-methods">
            <button class="payment-method-btn active" data-method="cash">Efectivo</button>
            <button class="payment-method-btn" data-method="card">Tarjeta</button>
          </div>
          
          <div id="cash-payment-details">
            <div class="form-group">
              <label for="amount-paid">Monto recibido</label>
              <input type="number" id="amount-paid" step="0.01" min="0">
            </div>
            
            <div class="payment-change">
              <span>Cambio:</span>
              <span id="payment-change">$0.00</span>
            </div>
          </div>
        </div>
        <div class="modal-footer">
          <button id="cancel-payment-btn">Cancelar</button>
          <button id="complete-payment-btn">Completar Pago</button>
        </div>
      </div>
    </div>
    
    <div id="cash-movement-modal" class="modal">
      <div class="modal-content">
        <div class="modal-header">
          <h2 id="cash-movement-title">Registrar Movimiento</h2>
          <span class="close-modal">&times;</span>
        </div>
        <div class="modal-body">
          <div class="form-group">
            <label for="movement-amount">Monto ($)</label>
            <input type="number" id="movement-amount" step="0.01" min="0">
          </div>
          
          <div class="form-group">
            <label for="movement-reason">Motivo</label>
            <input type="text" id="movement-reason" placeholder="Ingrese el motivo del movimiento">
          </div>
        </div>
        <div class="modal-footer">
          <button id="cancel-movement-btn">Cancelar</button>
          <button id="save-movement-btn">Guardar</button>
        </div>
      </div>
    </div>
    
    <div id="register-modal" class="modal">
      <div class="modal-content">
        <div class="modal-header">
          <h2 id="register-modal-title">Abrir Caja</h2>
          <span class="close-modal">&times;</span>
        </div>
        <div class="modal-body">
          <div class="form-group">
            <label for="register-amount">Monto ($)</label>
            <input type="number" id="register-amount" step="0.01" min="0">
          </div>
          
          <div class="form-group">
            <label for="register-notes">Notas (opcional)</label>
            <textarea id="register-notes" placeholder="Observaciones adicionales..."></textarea>
          </div>
        </div>
        <div class="modal-footer">
          <button id="cancel-register-btn">Cancelar</button>
          <button id="save-register-btn">Guardar</button>
        </div>
      </div>
    </div>
    
    <div id="sale-confirmation-modal" class="modal">
      <div class="modal-content">
        <div class="modal-header">
          <h2>Venta Completada</h2>
          <span class="close-modal">&times;</span>
        </div>
        <div class="modal-body">
          <div class="sale-confirmation">
            <img src="/images/success.png" alt="Éxito">
            <h3>¡Venta realizada con éxito!</h3>
            <div class="sale-details">
              <div class="sale-detail">
                <span>Total:</span>
                <span id="confirmation-total">$0.00</span>
              </div>
              <div class="sale-detail">
                <span>Método de pago:</span>
                <span id="confirmation-method">Efectivo</span>
              </div>
              <div id="confirmation-change-container" class="sale-detail">
                <span>Cambio:</span>
                <span id="confirmation-change">$0.00</span>
              </div>
            </div>
          </div>
        </div>
        <div class="modal-footer">
          <button id="print-receipt-btn">Imprimir Ticket</button>
          <button id="new-sale-btn">Nueva Venta</button>
        </div>
      </div>
    </div>
  </div>
  
  <script src="/socket.io/socket.io.js"></script>
  <script src="/js/app.js"></script>
</body>
</html>
EOL

# Crear estilos CSS
cat > ~/pos-system/public/css/styles.css << 'EOL'
/* Estilos optimizados para Raspberry Pi 3 */
:root {
  --primary: #4CAF50;
  --primary-dark: #388E3C;
  --primary-light: #C8E6C9;
  --accent: #FF9800;
  --text: #212121;
  --text-secondary: #757575;
  --divider: #BDBDBD;
  --background: #F5F5F5;
  --card: #FFFFFF;
  --error: #F44336;
  --success: #4CAF50;
}

* {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

body {
  font-family: Arial, sans-serif;
  background-color: var(--background);
  color: var(--text);
  line-height: 1.6;
}

#app {
  display: flex;
  flex-direction: column;
  min-height: 100vh;
}

/* Header */
header {
  background-color: var(--primary);
  color: white;
  padding: 0.5rem 1rem;
  display: flex;
  justify-content: space-between;
  align-items: center;
  box-shadow: 0 2px 4px rgba(0,0,0,0.1);
}

.logo {
  display: flex;
  align-items: center;
}

.logo-img {
  height: 40px;
  margin-right: 10px;
}

nav {
  display: flex;
  gap: 0.5rem;
}

.nav-btn {
  background: none;
  border: none;
  color: white;
  padding: 0.5rem 1rem;
  cursor: pointer;
  border-radius: 4px;
  font-weight: bold;
}

.nav-btn:hover {
  background-color: rgba(255,255,255,0.1);
}

.nav-btn.active {
  background-color: rgba(255,255,255,0.2);
}

.user-info {
  display: flex;
  align-items: center;
  gap: 1rem;
}

#logout-btn {
  background-color: rgba(255,255,255,0.2);
  border: none;
  color: white;
  padding: 0.25rem 0.5rem;
  border-radius: 4px;
  cursor: pointer;
}

/* Main content */
main {
  flex: 1;
  padding: 1rem;
  overflow-y: auto;
}

.page {
  display: none;
}

.page.active {
  display: block;
}

/* POS Page */
.pos-container {
  display: flex;
  gap: 1rem;
  height: calc(100vh - 120px);
}

.pos-left {
  flex: 2;
  display: flex;
  flex-direction: column;
  background-color: var(--card);
  border-radius: 4px;
  box-shadow: 0 1px 3px rgba(0,0,0,0.1);
  overflow: hidden;
}

.search-bar {
  padding: 1rem;
  display: flex;
  gap: 0.5rem;
  border-bottom: 1px solid var(--divider);
}

#barcode-input {
  flex: 1;
  padding: 0.5rem;
  border: 1px solid var(--divider);
  border-radius: 4px;
}

#search-btn {
  background-color: var(--primary);
  color: white;
  border: none;
  padding: 0.5rem 1rem;
  border-radius: 4px;
  cursor: pointer;
}

.categories {
  padding: 0.5rem;
  display: flex;
  gap: 0.5rem;
  overflow-x: auto;
  border-bottom: 1px solid var(--divider);
}

.category-btn {
  background-color: var(--primary-light);
  color: var(--primary-dark);
  border: none;
  padding: 0.25rem 0.5rem;
  border-radius: 4px;
  cursor: pointer;
  white-space: nowrap;
}

.category-btn.active {
  background-color: var(--primary);
  color: white;
}

.products-grid {
  flex: 1;
  padding: 1rem;
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(120px, 1fr));
  gap: 1rem;
  overflow-y: auto;
}

.product-card {
  background-color: white;
  border: 1px solid var(--divider);
  border-radius: 4px;
  padding: 0.5rem;
  cursor: pointer;
  transition: transform 0.2s;
  display: flex;
  flex-direction: column;
}

.product-card:hover {
  transform: translateY(-2px);
  box-shadow: 0 2px 4px rgba(0,0,0,0.1);
}

.product-image {
  width: 100%;
  height: 80px;
  background-color: #f0f0f0;
  border-radius: 4px;
  margin-bottom: 0.5rem;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 2rem;
  color: var(--text-secondary);
}

.product-name {
  font-weight: bold;
  font-size: 0.9rem;
  margin-bottom: 0.25rem;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.product-price {
  color: var(--primary-dark);
  font-weight: bold;
}

.product-category {
  font-size: 0.8rem;
  color: var(--text-secondary);
}

.pos-right {
  flex: 1;
  display: flex;
  flex-direction: column;
  background-color: var(--card);
  border-radius: 4px;
  box-shadow: 0 1px 3px rgba(0,0,0,0.1);
  overflow: hidden;
}

.cart-header {
  padding: 1rem;
  display: flex;
  justify-content: space-between;
  align-items: center;
  border-bottom: 1px solid var(--divider);
}

.cart-count {
  background-color: var(--primary-light);
  color: var(--primary-dark);
  padding: 0.25rem 0.5rem;
  border-radius: 4px;
  font-size: 0.8rem;
}

.cart-items {
  flex: 1;
  padding: 1rem;
  overflow-y: auto;
}

.empty-cart {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  height: 100%;
  color: var(--text-secondary);
}

.empty-cart img {
  width: 64px;
  height: 64px;
  margin-bottom: 1rem;
  opacity: 0.5;
}

.cart-item {
  display: flex;
  justify-content: space-between;
  padding: 0.5rem;
  border-bottom: 1px solid var(--divider);
}

.cart-item-info {
  flex: 1;
}

.cart-item-name {
  font-weight: bold;
}

.cart-item-price {
  font-size: 0.9rem;
  color: var(--text-secondary);
}

.cart-item-actions {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.cart-item-quantity {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.quantity-btn {
  background-color: var(--primary-light);
  color: var(--primary-dark);
  border: none;
  width: 24px;
  height: 24px;
  border-radius: 4px;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
}

.cart-item-total {
  font-weight: bold;
  color: var(--primary-dark);
}

.cart-footer {
  padding: 1rem;
  border-top: 1px solid var(--divider);
}

.cart-total {
  display: flex;
  justify-content: space-between;
  font-size: 1.2rem;
  font-weight: bold;
  margin-bottom: 1rem;
}

.cart-actions {
  display: flex;
  gap: 0.5rem;
}

#save-btn, #checkout-btn {
  flex: 1;
  padding: 0.5rem;
  border: none;
  border-radius: 4px;
  cursor: pointer;
  font-weight: bold;
}

#save-btn {
  background-color: var(--primary-light);
  color: var(--primary-dark);
}

#checkout-btn {
  background-color: var(--primary);
  color: white;
}

#save-btn:disabled, #checkout-btn:disabled {
  background-color: var(--divider);
  color: var(--text-secondary);
  cursor: not-allowed;
}

/* Products Page */
.products-actions {
  display: flex;
  justify-content: space-between;
  margin-bottom: 1rem;
}

#add-product-btn {
  background-color: var(--primary);
  color: white;
  border: none;
  padding: 0.5rem 1rem;
  border-radius: 4px;
  cursor: pointer;
}

#product-search {
  padding: 0.5rem;
  border: 1px solid var(--divider);
  border-radius: 4px;
  width: 300px;
}

.products-table {
  width: 100%;
  border-collapse: collapse;
  background-color: var(--card);
  box-shadow: 0 1px 3px rgba(0,0,0,0.1);
}

.products-table th, .products-table td {
  padding: 0.75rem;
  text-align: left;
  border-bottom: 1px solid var(--divider);
}

.products-table th {
  background-color: var(--primary-light);
  color: var(--primary-dark);
}

.products-table tr:hover {
  background-color: rgba(0,0,0,0.02);
}

/* Sales Page */
.sales-filters {
  display: flex;
  gap: 1rem;
  margin-bottom: 1rem;
}

.sales-filters input {
  padding: 0.5rem;
  border: 1px solid var(--divider);
  border-radius: 4px;
}

#filter-sales-btn {
  background-color: var(--primary);
  color: white;
  border: none;
  padding: 0.5rem 1rem;
  border-radius: 4px;
  cursor: pointer;
}

.sales-table {
  width: 100%;
  border-collapse: collapse;
  background-color: var(--card);
  box-shadow: 0 1px 3px rgba(0,0,0,0.1);
}

.sales-table th, .sales-table td {
  padding: 0.75rem;
  text-align: left;
  border-bottom: 1px solid var(--divider);
}

.sales-table th {
  background-color: var(--primary-light);
  color: var(--primary-dark);
}

.sales-table tr:hover {
  background-color: rgba(0,0,0,0.02);
}

/* Cash Register Page */
.cash-register-status {
  background-color: var(--card);
  border-radius: 4px;
  box-shadow: 0 1px 3px rgba(0,0,0,0.1);
  padding: 1rem;
  margin-bottom: 1rem;
}

.cash-register-message {
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: 2rem;
}

.cash-register-message img {
  width: 64px;
  height: 64px;
  margin-bottom: 1rem;
  opacity: 0.5;
}

.cash-register-message h3 {
  margin-bottom: 0.5rem;
}

.cash-register-message p {
  color: var(--text-secondary);
  margin-bottom: 1rem;
}

#open-register-btn {
  background-color: var(--primary);
  color: white;
  border: none;
  padding: 0.5rem 1rem;
  border-radius: 4px;
  cursor: pointer;
}

.cash-register-info {
  margin-bottom: 1rem;
}

.cash-register-details {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 1rem;
  margin: 1rem 0;
}

.cash-detail {
  background-color: var(--primary-light);
  padding: 1rem;
  border-radius: 4px;
  display: flex;
  flex-direction: column;
}

.cash-detail span:first-child {
  font-size: 0.9rem;
  color: var(--primary-dark);
}

.cash-detail span:last-child {
  font-size: 1.2rem;
  font-weight: bold;
}

.cash-actions {
  display: flex;
  gap: 1rem;
}

.cash-actions button {
  flex: 1;
  padding: 0.5rem;
  border: none;
  border-radius: 4px;
  cursor: pointer;
}

#add-cash-btn {
  background-color: var(--success);
  color: white;
}

#remove-cash-btn {
  background-color: var(--error);
  color: white;
}

#close-register-btn {
  background-color: var(--primary);
  color: white;
}

.cash-movements h3 {
  margin-bottom: 1rem;
}

.movements-table {
  width: 100%;
  border-collapse: collapse;
  background-color: var(--card);
  box-shadow: 0 1px 3px rgba(0,0,0,0.1);
}

.movements-table th, .movements-table td {
  padding: 0.75rem;
  text-align: left;
  border-bottom: 1px solid var(--divider);
}

.movements-table th {
  background-color: var(--primary-light);
  color: var(--primary-dark);
}

/* Modals */
.modal {
  display: none;
  position: fixed;
  top: 0;
  left: 0;
  width: 100%;
  height: 100%;
  background-color: rgba(0,0,0,0.5);
  z-index: 1000;
  align-items: center;
  justify-content: center;
}

.modal.active {
  display: flex;
}

.modal-content {
  background-color: var(--card);
  border-radius: 4px;
  width: 100%;
  max-width: 500px;
  box-shadow: 0 4px 8px rgba(0,0,0,0.2);
}

.modal-header {
  padding: 1rem;
  display: flex;
  justify-content: space-between;
  align-items: center;
  border-bottom: 1px solid var(--divider);
}

.close-modal {
  font-size: 1.5rem;
  cursor: pointer;
}

.modal-body {
  padding: 1rem;
}

.modal-footer {
  padding: 1rem;
  display: flex;
  justify-content: flex-end;
  gap: 1rem;
  border-top: 1px solid var(--divider);
}

.modal-footer button {
  padding: 0.5rem 1rem;
  border: none;
  border-radius: 4px;
  cursor: pointer;
}

.modal-footer button:first-child {
  background-color: var(--divider);
  color: var(--text);
}

.modal-footer button:last-child {
  background-color: var(--primary);
  color: white;
}

/* Payment Modal */
.payment-total {
  display: flex;
  justify-content: space-between;
  font-size: 1.2rem;
  font-weight: bold;
  margin-bottom: 1rem;
  padding: 1rem;
  background-color: var(--primary-light);
  border-radius: 4px;
}

.payment-methods {
  display: flex;
  gap: 1rem;
  margin-bottom: 1rem;
}

.payment-method-btn {
  flex: 1;
  padding: 0.5rem;
  border: 1px solid var(--primary);
  border-radius: 4px;
  background-color: white;
  color: var(--primary);
  cursor: pointer;
}

.payment-method-btn.active {
  background-color: var(--primary);
  color: white;
}

.form-group {
  margin-bottom: 1rem;
}

.form-group label {
  display: block;
  margin-bottom: 0.5rem;
  font-weight: bold;
}

.form-group input, .form-group textarea {
  width: 100%;
  padding: 0.5rem;
  border: 1px solid var(--divider);
  border-radius: 4px;
}

.payment-change {
  display: flex;
  justify-content: space-between;
  padding: 0.5rem;
  background-color: var(--background);
  border-radius: 4px;
  margin-top: 1rem;
}

/* Sale Confirmation Modal */
.sale-confirmation {
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: 1rem;
}

.sale-confirmation img {
  width: 64px;
  height: 64px;
  margin-bottom: 1rem;
}

.sale-confirmation h3 {
  margin-bottom: 1rem;
  color: var(--success);
}

.sale-details {
  width: 100%;
  margin-top: 1rem;
}

.sale-detail {
  display: flex;
  justify-content: space-between;
  padding: 0.5rem;
  border-bottom: 1px solid var(--divider);
}

.sale-detail:last-child {
  border-bottom: none;
}

/* Utility Classes */
.hidden {
  display: none !important;
}
EOL

# Crear JavaScript principal
cat > ~/pos-system/public/js/app.js << 'EOL'
// Aplicación POS optimizada para Raspberry Pi 3
document.addEventListener('DOMContentLoaded', () => {
  // Inicialización
  const socket = io();
  let products = [];
  let categories = [];
  let cart = [];
  let currentPage = 'pos';
  let selectedCategory = 'all';
  let cashRegister = null;
  let movementType = 'add';
  let completedSale = null;
  
  // Elementos DOM
  const pages = document.querySelectorAll('.page');
  const navButtons = document.querySelectorAll('.nav-btn');
  const productsGrid = document.getElementById('products-grid');
  const cartItemsContainer = document.getElementById('cart-items');
  const cartTotalElement = document.getElementById('cart-total');
  const cartCountElement = document.querySelector('.cart-count');
  const checkoutBtn = document.getElementById('checkout-btn');
  const saveBtn = document.getElementById('save-btn');
  const barcodeInput = document.getElementById('barcode-input');
  const searchBtn = document.getElementById('search-btn');
  
  // Modales
  const paymentModal = document.getElementById('payment-modal');
  const paymentTotalElement = document.getElementById('payment-total-amount');
  const amountPaidInput = document.getElementById('amount-paid');
  const paymentChangeElement = document.getElementById('payment-change');
  const paymentMethodBtns = document.querySelectorAll('.payment-method-btn');
  const cashPaymentDetails = document.getElementById('cash-payment-details');
  const completePaymentBtn = document.getElementById('complete-payment-btn');
  const cancelPaymentBtn = document.getElementById('cancel-payment-btn');
  
  const saleConfirmationModal = document.getElementById('sale-confirmation-modal');
  const confirmationTotalElement = document.getElementById('confirmation-total');
  const confirmationMethodElement = document.getElementById('confirmation-method');
  const confirmationChangeContainer = document.getElementById('confirmation-change-container');
  const confirmationChangeElement = document.getElementById('confirmation-change');
  const printReceiptBtn = document.getElementById('print-receipt-btn');
  const newSaleBtn = document.getElementById('new-sale-btn');
  
  const cashMovementModal = document.getElementById('cash-movement-modal');
  const cashMovementTitle = document.getElementById('cash-movement-title');
  const movementAmountInput = document.getElementById('movement-amount');
  const movementReasonInput = document.getElementById('movement-reason');
  const saveMovementBtn = document.getElementById('save-movement-btn');
  const cancelMovementBtn = document.getElementById('cancel-movement-btn');
  
  const registerModal = document.getElementById('register-modal');
  const registerModalTitle = document.getElementById('register-modal-title');
  const registerAmountInput = document.getElementById('register-amount');
  const registerNotesInput = document.getElementById('register-notes');
  const saveRegisterBtn = document.getElementById('save-register-btn');
  const cancelRegisterBtn = document.getElementById('cancel-register-btn');
  
  // Elementos de caja
  const cashRegisterClosed = document.getElementById('cash-register-closed');
  const cashRegisterOpen = document.getElementById('cash-register-open');
  const openRegisterBtn = document.getElementById('open-register-btn');
  const closeRegisterBtn = document.getElementById('close-register-btn');
  const addCashBtn = document.getElementById('add-cash-btn');
  const removeCashBtn = document.getElementById('remove-cash-btn');
  const initialAmountElement = document.getElementById('initial-amount');
  const expectedAmountElement = document.getElementById('expected-amount');
  const elapsedTimeElement = document.getElementById('elapsed-time');
  const movementsTableBody = document.getElementById('movements-table-body');
  
  // Cargar datos iniciales
  loadProducts();
  loadCategories();
  checkCashRegister();
  
  // Eventos de navegación
  navButtons.forEach(button => {
    button.addEventListener('click', () => {
      const page = button.dataset.page;
      changePage(page);
    });
  });
  
  // Eventos de POS
  barcodeInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      const barcode = e.target.value.trim();
      if (barcode) {
        findProductByBarcode(barcode);
        e.target.value = '';
      }
    }
  });
  
  searchBtn.addEventListener('click', () => {
    const barcode = barcodeInput.value.trim();
    if (barcode) {
      findProductByBarcode(barcode);
      barcodeInput.value = '';
    }
  });
  
  // Eventos de pago
  checkoutBtn.addEventListener('click', () => {
    if (cart.length === 0) return;
    
    // Configurar modal de pago
    paymentTotalElement.textContent = `$${calculateTotal().toFixed(2)}`;
    amountPaidInput.value = calculateTotal().toFixed(2);
    updatePaymentChange();
    
    // Mostrar modal
    paymentModal.classList.add('active');
    amountPaidInput.focus();
  });
  
  amountPaidInput.addEventListener('input', updatePaymentChange);
  
  paymentMethodBtns.forEach(btn => {
    btn.addEventListener('click', () => {
      paymentMethodBtns.forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      
      const method = btn.dataset.method;
      if (method === 'cash') {
        cashPaymentDetails.classList.remove('hidden');
      } else {
        cashPaymentDetails.classList.add('hidden');
      }
    });
  });
  
  completePaymentBtn.addEventListener('click', processPayment);
  cancelPaymentBtn.addEventListener('click', () => {
    paymentModal.classList.remove('active');
  });
  
  // Eventos de confirmación de venta
  printReceiptBtn.addEventListener('click', printReceipt);
  newSaleBtn.addEventListener('click', () => {
    saleConfirmationModal.classList.remove('active');
    clearCart();
  });
  
  // Eventos de caja
  openRegisterBtn.addEventListener('click', () => {
    registerModalTitle.textContent = 'Abrir Caja';
    registerAmountInput.value = '';
    registerNotesInput.value = '';
    registerModal.classList.add('active');
    registerAmountInput.focus();
  });
  
  closeRegisterBtn.addEventListener('click', () => {
    registerModalTitle.textContent = 'Cerrar Caja';
    registerAmountInput.value = '';
    registerNotesInput.value = '';
    registerModal.classList.add('active');
    registerAmountInput.focus();
  });
  
  addCashBtn.addEventListener('click', () => {
    cashMovementTitle.textContent = 'Registrar Ingreso';
    movementType = 'add';
    movementAmountInput.value = '';
    movementReasonInput.value = '';
    cashMovementModal.classList.add('active');
    movementAmountInput.focus();
  });
  
  removeCashBtn.addEventListener('click', () => {
    cashMovementTitle.textContent = 'Registrar Retiro';
    movementType = 'remove';
    movementAmountInput.value = '';
    movementReasonInput.value = '';
    cashMovementModal.classList.add('active');
    movementAmountInput.focus();
  });
  
  saveRegisterBtn.addEventListener('click', handleRegisterAction);
  cancelRegisterBtn.addEventListener('click', () => {
    registerModal.classList.remove('active');
  });
  
  saveMovementBtn.addEventListener('click', handleCashMovement);
  cancelMovementBtn.addEventListener('click', () => {
    cashMovementModal.classList.remove('active');
  });
  
  // Cerrar modales al hacer clic en X
  document.querySelectorAll('.close-modal').forEach(closeBtn => {
    closeBtn.addEventListener('click', () => {
      document.querySelectorAll('.modal').forEach(modal => {
        modal.classList.remove('active');
      });
    });
  });
  
  // Eventos de socket
  socket.on('product-updated', () => {
    loadProducts();
  });
  
  socket.on('sale-completed', () => {
    if (currentPage === 'sales') {
      loadSales();
    }
  });
  
  socket.on('cash-register-updated', () => {
    checkCashRegister();
  });
  
  // Atajos de teclado
  document.addEventListener('keydown', (e) => {
    // F9 para enfocar el input de código de barras
    if (e.key === 'F9') {
      e.preventDefault();
      barcodeInput.focus();
    }
    // F8 para abrir el modal de pago
    else if (e.key === 'F8' && cart.length > 0) {
      e.preventDefault();
      checkoutBtn.click();
    }
    // F7 para guardar ticket
    else if (e.key === 'F7' && cart.length > 0) {
      e.preventDefault();
      saveBtn.click();
    }
  });
  
  // Funciones
  function changePage(page) {
    currentPage = page;
    
    // Actualizar navegación
    navButtons.forEach(btn => {
      btn.classList.toggle('active', btn.dataset.page === page);
    });
    
    // Mostrar página correspondiente
    pages.forEach(p => {
      p.classList.toggle('active', p.id === `${page}-page`);
    });
    
    // Acciones específicas por página
    if (page === 'pos') {
      barcodeInput.focus();
    } else if (page === 'products') {
      loadProductsTable();
    } else if (page === 'sales') {
      loadSales();
    } else if (page === 'cash') {
      checkCashRegister();
    }
  }
  
  async function loadProducts() {
    try {
      const response = await fetch('/api/products');
      products = await response.json();
      renderProducts();
    } catch (error) {
      console.error('Error al cargar productos:', error);
    }
  }
  
  async function loadCategories() {
    try {
      const response = await fetch('/api/categories');
      categories = await response.json();
      renderCategories();
    } catch (error) {
      console.error('Error al cargar categorías:', error);
    }
  }
  
  function renderProducts() {
    productsGrid.innerHTML = '';
    
    const filteredProducts = selectedCategory === 'all' 
      ? products 
      : products.filter(p => p.category_id === selectedCategory);
    
    if (filteredProducts.length === 0) {
      productsGrid.innerHTML = '<div class="empty-products">No hay productos en esta categoría</div>';
      return;
    }
    
    filteredProducts.forEach(product => {
      const productCard = document.createElement('div');
      productCard.className = 'product-card';
      productCard.innerHTML = `
        <div class="product-image">${product.image ? `<img src="${product.image}" alt="${product.name}">` : product.name.charAt(0)}</div>
        <div class="product-name">${product.name}</div>
        <div class="product-price">$${product.price.toFixed(2)}</div>
        <div class="product-category">${getCategoryName(product.category_id)}</div>
      `;
      productCard.addEventListener('click', () => addToCart(product));
      productsGrid.appendChild(productCard);
    });
  }
  
  function renderCategories() {
    const categoriesContainer = document.querySelector('.categories');
    categoriesContainer.innerHTML = '<button class="category-btn active" data-category="all">Todos</button>';
    
    categories.forEach(category => {
      const categoryBtn = document.createElement('button');
      categoryBtn.className = 'category-btn';
      categoryBtn.dataset.category = category.id;
      categoryBtn.textContent = category.name;
      categoryBtn.addEventListener('click', () => {
        document.querySelectorAll('.category-btn').forEach(btn => btn.classList.remove('active'));
        categoryBtn.classList.add('active');
        selectedCategory = category.id;
        renderProducts();
      });
      categoriesContainer.appendChild(categoryBtn);
    });
  }
  
  function getCategoryName(categoryId) {
    if (!categoryId) return 'Sin categoría';
    const category = categories.find(c => c.id === categoryId);
    return category ? category.name : 'Sin categoría';
  }
  
  function findProductByBarcode(barcode) {
    const product = products.find(p => p.barcode === barcode);
    if (product) {
      addToCart(product);
    } else {
      alert('Producto no encontrado');
    }
  }
  
  function addToCart(product) {
    const existingItem = cart.find(item => item.product_id === product.id);
    
    if (existingItem) {
      existingItem.quantity += 1;
      existingItem.total = existingItem.quantity * existingItem.price;
    } else {
      cart.push({
        product_id: product.id,
        name: product.name,
        price: product.price,
        quantity: 1,
        total: product.price
      });
    }
    
    renderCart();
    updateCartButtons();
  }
  
  function removeFromCart(productId) {
    cart = cart.filter(item => item.product_id !== productId);
    renderCart();
    updateCartButtons();
  }
  
  function updateQuantity(productId, newQuantity) {
    if (newQuantity <= 0) {
      removeFromCart(productId);
      return;
    }
    
    const item = cart.find(item => item.product_id === productId);
    if (item) {
      item.quantity = newQuantity;
      item.total = item.quantity * item.price;
      renderCart();
    }
  }
  
  function renderCart() {
    if (cart.length === 0) {
      cartItemsContainer.innerHTML = `
        <div class="empty-cart">
          <img src="/images/cart.png" alt="Carrito vacío">
          <p>El carrito está vacío</p>
        </div>
      `;
    } else {
      cartItemsContainer.innerHTML = '';
      
      cart.forEach(item => {
        const cartItem = document.createElement('div');
        cartItem.className = 'cart-item';
        cartItem.innerHTML = `
          <div class="cart-item-info">
            <div class="cart-item-name">${item.name}</div>
            <div class="cart-item-price">$${item.price.toFixed(2)}</div>
          </div>
          <div class="cart-item-actions">
            <div class="cart-item-quantity">
              <button class="quantity-btn" data-action="decrease" data-id="${item.product_id}">-</button>
              <span>${item.quantity}</span>
              <button class="quantity-btn" data-action="increase" data-id="${item.product_id}">+</button>
            </div>
            <div class="cart-item-total">$${item.total.toFixed(2)}</div>
          </div>
        `;
        
        cartItemsContainer.appendChild(cartItem);
      });
      
      // Agregar eventos a los botones de cantidad
      document.querySelectorAll('.quantity-btn').forEach(btn => {
        btn.addEventListener('click', () => {
          const productId = btn.dataset.id;
          const action = btn.dataset.action;
          const item = cart.find(item => item.product_id === productId);
          
          if (item) {
            if (action === 'increase') {
              updateQuantity(productId, item.quantity + 1);
            } else if (action === 'decrease') {
              updateQuantity(productId, item.quantity - 1);
            }
          }
        });
      });
    }
    
    // Actualizar total y contador
    cartTotalElement.textContent = `$${calculateTotal().toFixed(2)}`;
    cartCountElement.textContent = `${cart.length} items`;
  }
  
  function calculateTotal() {
    return cart.reduce((total, item) => total + item.total, 0);
  }
  
  function updateCartButtons() {
    const hasItems = cart.length > 0;
    checkoutBtn.disabled = !hasItems;
    saveBtn.disabled = !hasItems;
  }
  
  function updatePaymentChange() {
    const total = calculateTotal();
    const amountPaid = parseFloat(amountPaidInput.value) || 0;
    const change = amountPaid - total;
    
    paymentChangeElement.textContent = `$${Math.max(0, change).toFixed(2)}`;
    paymentChangeElement.parentElement.classList.toggle('text-error', change < 0);
  }
  
  async function processPayment() {
    const total = calculateTotal();
    const amountPaid = parseFloat(amountPaidInput.value) || 0;
    const activeMethod = document.querySelector('.payment-method-btn.active');
    const paymentMethod = activeMethod ? activeMethod.dataset.method : 'cash';
    
    // Validar pago en efectivo
    if (paymentMethod === 'cash' && amountPaid < total) {
      alert('El monto pagado debe ser mayor o igual al total');
      return;
    }
    
    try {
      // Preparar datos de la venta
      const sale = {
        date: new Date().toISOString(),
        total: total,
        payment_method: paymentMethod,
        amount_paid: paymentMethod === 'cash' ? amountPaid : total,
        change_amount: paymentMethod === 'cash' ? amountPaid - total : 0,
        cashier: document.getElementById('cashier-name').textContent,
        items: cart.map(item => ({
          product_id: item.product_id,
          quantity: item.quantity,
          price: item.price,
          total: item.total
        }))
      };
      
      // Enviar venta al servidor
      const response = await fetch('/api/sales', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(sale)
      });
      
      const result = await response.json();
      
      if (result.id) {
        // Guardar venta completada
        completedSale = {
          sale: result,
          items: cart
        };
        
        // Cerrar modal de pago
        paymentModal.classList.remove('active');
        
        // Mostrar confirmación
        confirmationTotalElement.textContent = `$${total.toFixed(2)}`;
        confirmationMethodElement.textContent = paymentMethod === 'cash' ? 'Efectivo' : 'Tarjeta';
        
        if (paymentMethod === 'cash') {
          confirmationChangeContainer.classList.remove('hidden');
          confirmationChangeElement.textContent = `$${(amountPaid - total).toFixed(2)}`;
        } else {
          confirmationChangeContainer.classList.add('hidden');
        }
        
        saleConfirmationModal.classList.add('active');
      }
    } catch (error) {
      console.error('Error al procesar pago:', error);
      alert('Error al procesar el pago');
    }
  }
  
  async function printReceipt() {
    if (!completedSale) return;
    
    try {
      await fetch('/api/print', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(completedSale)
      });
    } catch (error) {
      console.error('Error al imprimir:', error);
    }
  }
  
  function clearCart() {
    cart = [];
    renderCart();
    updateCartButtons();
  }
  
  async function checkCashRegister() {
    try {
      const response = await fetch('/api/cash/current');
      cashRegister = await response.json();
      
      if (cashRegister) {
        // Mostrar caja abierta
        cashRegisterClosed.classList.add('hidden');
        cashRegisterOpen.classList.remove('hidden');
        
        // Actualizar información
        initialAmountElement.textContent = `$${cashRegister.initial_amount.toFixed(2)}`;
        expectedAmountElement.textContent = `$${cashRegister.expected_amount.toFixed(2)}`;
        
        // Calcular tiempo transcurrido
        updateElapsedTime();
        
        // Mostrar movimientos
        renderCashMovements(cashRegister.movements || []);
      } else {
        // Mostrar caja cerrada
        cashRegisterClosed.classList.remove('hidden');
        cashRegisterOpen.classList.add('hidden');
      }
    } catch (error) {
      console.error('Error al verificar caja:', error);
    }
  }
  
  function updateElapsedTime() {
    if (!cashRegister) return;
    
    const openDate = new Date(cashRegister.open_date);
    const now = new Date();
    const diffMs = now - openDate;
    const diffHrs = Math.floor(diffMs / (1000 * 60 * 60));
    const diffMins = Math.floor((diffMs % (1000 * 60 * 60)) / (1000 * 60));
    
    elapsedTimeElement.textContent = `${diffHrs}h ${diffMins}m`;
  }
  
  function renderCashMovements(movements) {
    movementsTableBody.innerHTML = '';
    
    if (movements.length === 0) {
      movementsTableBody.innerHTML = '<tr><td colspan="4" class="text-center">No hay movimientos registrados</td></tr>';
      return;
    }
    
    movements.forEach(movement => {
      const row = document.createElement('tr');
      row.innerHTML = `
        <td>${formatDate(movement.date)}</td>
        <td class="${movement.type === 'add' ? 'text-success' : 'text-error'}">${movement.type === 'add' ? 'Ingreso' : 'Retiro'}</td>
        <td>$${movement.amount.toFixed(2)}</td>
        <td>${movement.reason || '-'}</td>
      `;
      movementsTableBody.appendChild(row);
    });
  }
  
  async function handleRegisterAction() {
    const amount = parseFloat(registerAmountInput.value);
    const notes = registerNotesInput.value;
    
    if (isNaN(amount) || amount <= 0) {
      alert('Por favor ingrese un monto válido');
      return;
    }
    
    try {
      if (registerModalTitle.textContent === 'Abrir Caja') {
        // Abrir caja
        await fetch('/api/cash/open', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json'
          },
          body: JSON.stringify({
            initial_amount: amount,
            notes: notes,
            opened_by: document.getElementById('cashier-name').textContent
          })
        });
      } else {
        // Cerrar caja
        await fetch('/api/cash/close', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json'
          },
          body: JSON.stringify({
            register_id: cashRegister.id,
            final_amount: amount,
            notes: notes,
            closed_by: document.getElementById('cashier-name').textContent
          })
        });
      }
      
      registerModal.classList.remove('active');
      checkCashRegister();
    } catch (error) {
      console.error('Error al gestionar caja:', error);
      alert('Error al procesar la operación');
    }
  }
  
  async function handleCashMovement() {
    const amount = parseFloat(movementAmountInput.value);
    const reason = movementReasonInput.value;
    
    if (isNaN(amount) || amount <= 0) {
      alert('Por favor ingrese un monto válido');
      return;
    }
    
    if (!reason.trim()) {
      alert('Por favor ingrese un motivo para el movimiento');
      return;
    }
    
    try {
      await fetch('/api/cash/movement', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          register_id: cashRegister.id,
          type: movementType,
          amount: amount,
          reason: reason,
          user_id: document.getElementById('cashier-name').textContent
        })
      });
      
      cashMovementModal.classList.remove('active');
      checkCashRegister();
    } catch (error) {
      console.error('Error al registrar movimiento:', error);
      alert('Error al procesar la operación');
    }
  }
  
  function formatDate(dateString) {
    const date = new Date(dateString);
    return `${date.getDate()}/${date.getMonth() + 1}/${date.getFullYear()} ${date.getHours()}:${date.getMinutes()}`;
  }
  
  // Actualizar tiempo transcurrido cada minuto
  setInterval(() => {
    if (cashRegister && cashRegister.status === 'open') {
      updateElapsedTime();
    }
  }, 60000);
});
EOL

# Crear manifest.json
cat > ~/pos-system/public/manifest.json << 'EOL'
{
  "name": "Sistema POS",
  "short_name": "POS",
  "description": "Sistema de punto de venta optimizado para Raspberry Pi",
  "start_url": "/",
  "display": "standalone",
  "background_color": "#ffffff",
  "theme_color": "#4CAF50",
  "icons": [
    {
      "src": "/images/icon-192.png",
      "sizes": "192x192",
      "type": "image/png"
    },
    {
      "src": "/images/icon-512.png",
      "sizes": "512x512",
      "type": "image/png"
    }
  ]
}
EOL

# Crear imágenes básicas
mkdir -p ~/pos-system/public/images
cat > ~/pos-system/public/images/logo.png << 'EOL'
iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAAACXBIWXMAAAsTAAALEwEAmpwYAAADsUlEQVR4nO2ZW4hNURjHf2PMmBljXMYtl3EpuTRC5JJbSikvlFJePHhAKU+UB+VBeVBKKcqDcinlUiTlUi65lGsYM+SSy4xx2Vqr/U3tTmefvfaZM3ufOvWvqTlrfev7/r+99re+9e0DLbTwf9MBGAcsBw4Ap4AHwCvgK/AD+AY8B+4Ce4GlwGigXdaONwEDgA3AQ6AO+Av8c7RfwDPgMLAA6JWF432BdcA1x4FYegVsA/pnFXgvYCdQk9Lx+roLLALapxF8e2AecDsD5+vrGTAXaBPH+VbADOBJxsHXVy2wGWgdJfiBwK0mDt5VDbA0LPjOwOEmWmZh9AvoF+T8QOBDMwreVQ0wKNeJXsD7Zgw+R+1cJ1YCfzIKvgb4DLwEHgF3gOvAJeAscAI4ChwCDgJ7gO3AWmAFsAiYBcwApgKTgQnAWGAUMBwYAgwCegLdgI5AK6VWwHLgT4Lg3wGngc3AYmAqMFKvYRJaAWOAhcAW4JJeq8HgfwJDXQcWJQj+K3ABOxmmA2OA7gmCDqMDMBE4BtQGBP8bGOE6sNEz+N/AXWAXsBKYAwxL+TcJQ2dgFnBCl0Vv8Dtc4/GeN/5VYDUwHuiQYaBBdNdVLWzJrXCNxwY4/0CfHrOBbk0ccBDdgCXAswDnJ7jGwwOcXwN0zTDQKHTRJ1dQ8CNd4/4Bzq/LMMAkrA1wfohrfC7A+SUZB5iEJQHO93eNbwQ4PyLDAJPQGXgf4HxP1/hugPNdMwwwCd0CnO/sGn8KcL5dhgEmIczv767xtwDj1hkGmIQwv9+6xrUBxh0zDDAJYX7XuMZvA4yvZBhgEsL8fuUavwwwvphhgEkI8/uFa3wuwHhfhgEmIczvc67xiQDjrRkGmIQwv4+7xhsCjDdlGGASZgb4vd41XhXgfF2GASahDntuBPm9wjXuCzwPcP5XxkEm4XeA3z2wNzMv+gQ4D/ZsaK5UB/i9zDUeBJz3dOB8M3gTc/kU4PdgYJNrPAJ7G/J14GEzCL4O2Bnk9zDgqms8CdtO4OvEuWZwJ2qxNzLf4LsAV1zjqdhqoK8Td7GFsObCG2Cyr9/Y9oVzrnEbbI+KrxO7tQzYlNRiS4++wbfFdkKddo3bYDvVfJ04pDdCU1GDvVn5Bt8WWIttYHCNWwOztdYeFFhdbVNQi70EBgXfClsGT+gN6xq3wjbHzMc2ygcFuCHDm7gaWwYPCn4etnoR9Gk7Ddv9FhTk+gxu6BZaaKGZ8h8JWRLvnHAWwQAAAABJRU5ErkJggg==
EOL

cat > ~/pos-system/public/images/cart.png << 'EOL'
iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAAACXBIWXMAAAsTAAALEwEAmpwYAAAC+UlEQVR4nO2ZS2gTURSGv1htRUWlPhBfFRQVH6ioWLWCKFoXdaGIGxeuBBFcuXMjrgRdiKILceHCKrpSEayCViwiKGpFfKFVUbRqxbZqH9oYOZMzYTKZO5OZSdOF+cNlMnPvOf+Zc8+5/z0DFVRQQTliBJgGngIfgVGgKk+HO4A3QMKyN0BnXg7XA0+xJ2/ZE6AuD+cngDGP5C17Ckwo+VQDXAQWgB/AWWCFZMIpn+QteyeZdBw4D8wDs8ARoEbC+euA5G1WK5nYBUz6JG+xicDJbwTuByRvsTuSyVvWGJK8ZQ2SyTcAr0OSt+yVZPLNwFRI8pY1Sya/FZgJSd6yGcnkdwBzIclbNiuZfBcwH5K8ZXOSyR8ElkKSt2xRMvkTEchbdlwy+VPAckTyy5LJnwGWIpJflEz+PLAQkfyCZPKXgB8Ryf+QTP4q8C0i+W+SyV8HZiOSnwGuSSZ/C/gckfxn4KZk8veAjxHJfwTuSib/EHgfkfx74IFk8k+BNxHJvwGeSCb/AngVkfwr4Llk8q+B8Yjkx4FXksnPAM8ikn8GzEgmvwi0AXXAJqAXGAImHX1+CpgCJoAhoAdo9bFW4LBPv0ngCbAuTvLbgIvAO5/lLWlzwDAwCOwBNvj0qwEOAVeALz79vgLXgM1Rk+8GHgHTIQexbBa4D+wH1vr0awKOAXeA7wH6fQJOA+tTJb8yVdkHgPMpK5Nt8tl2Czjm6NcInAQepnYHv37zwCVgS1DyG4EzwJsYk3faBHAD2OXotwu4niqBIP2mgD6gPl3yB1KHRlHJO20euAps9+jXDlwGvgTsNwYcTU/+WkHJO20aGHCsRB1wGhgN2O8hsCOVfFEt7bLbDv/3AhMB+wwCLUW3tMvGHP53AJ8C9OkrhaVd9tLhf1BdqK8Ulnb5H1QX6iuFpV3+7wXmAvTpK4WlXf53p0o9nb0FdpbC0i7/O4HnwJLDPqfqTKLIl3b5X5kqhRGgGdhblP8VVFBBBf8V/gIYQszn0RCaJQAAAABJRU5ErkJggg==
EOL

cat > ~/pos-system/public/images/success.png << 'EOL'
iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAAACXBIWXMAAAsTAAALEwEAmpwYAAAELUlEQVR4nO2ZW4hVVRjHf3PmzHhmxks6kTpFEV2oKCGiC9EFevARIkzsoaIHqQcpuiCBD0EPUdBLdKGIgiCC6EJE9hRFZGBEF7vQTSPtYk5qjs7MnDlzps9a8204HM+ZvdfaZ/bZB/aPhbP3+va3/t/69tprfWvDOtaxjnWkpQnADcBLwOfAz8BvwDTwF/AH8BPwFfAOcD9wGdBSqcGtBc4EngJ2A38DiwHtb+AH4HXgVmBDuYe1CTgfeAP4K8Xg4+wv4F3gKqC5HIPaCDwK/JzR4OP2I/AQsK6IwZ0GbAd+L3DwcfsVeAA4tYjBXwx8X+Lg4/YNcFHeg78N+LNCg4/bLuDmPAZ/MrCjwoOP2/vAhqwGfwrwUZUGH7ePgVOzGPwJwLtVHnzcPgBWpRn8CuDNGhl83N4AVoYO/njg1RodfNxeAY4LGfxx1PbgLdsZMviXa3zwlr0UMvgXCxr8X8CnwIvAE8D9wB3ADcDlwHnAWcBpwEnAscBK6/+tAe4BdgdcxReCBr+9gMHvA14DbgLOAY4JGMcxwLnAfcAnAeN4Pmjw2wocvFa+x4FzUo5hFXAr8FXKsTwbNPjtBQz+G+AeYH0OY1kP3At8m2I8TwcNfnvOg/8ReBg4PecxrQEeAfalGNeTQYN/PcfBfwfcDawueGwnAC8FjO/xoMG/ltPgvwQGgJUljnEl8GDA+B4NGvyrOQz+U+AKoKmM42wCrgQ+Cxjng0GDfyXj4D8GtgKryzzWJuAq4IuAMd8fNPiXMwz+Q+AyoLFC420GrgY+DxjzfUGDfynl4N8HLq7wWFuAa4E9AeO+O2jwL6YY/HvARVUa5zrgBmBvwNjvDBr8CykGvwO4oIrj3AjcBOwLGPvtQYN/PnDwbwPnV3mMm4FbgP0BY78laPDPBQ7+LeCcGhjfOcDtgWO/OWjwzwQOXpuCzTUyvs3AHYFjvzFo8E8HDv71GlqBtPG9ETj2G4IG/1Tg4F+twRVI298rAeO+LmjwTwYO/uUaXYG0/b0UMO5rgwb/RODgX6zhFUjb34sB474maPCPBw7+hTpYgbT9PR8w7quDBv9Y4OCfq5MVSNvfswHjvjJo8I8GDv6ZOlqBtP09HTDuK4IG/0jg4J+qsxVI29+TAeO+PGjwDwcO/ok6XIGk/h4NGPdlQYN/KHDwj9fpCiT192DAuC8NGvyDgYN/tI5XIKm/BwLGfUnQ4B8IHPwjDbACSf3dHzDui4MG/0Dg4B9ukBVI6u++gHFfFDT4+wIHf3+DrUBSf/cGjPvCoMHfGzj4+xpwBZL6uyf0A+cHDv7eBl2BpP7uDhn8nsDB39PAK5DU390hg/89cPB3NfgKJPV3V8jgfwsc/J0sXYGk/u4MGfw+li5Ckn0bMvh1rGMd61jHEvoXVhLWzHi8EOIAAAAASUVORK5CYII=
EOL

cat > ~/pos-system/public/images/cash-register.png << 'EOL'
iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAAACXBIWXMAAAsTAAALEwEAmpwYAAADqElEQVR4nO2ZXYhNURTHf3fGGBnzeYnJRxTlIyNCeVAeeJCUPCgPSsqLB0V5kTxIeVBeKCklD0qRlJJSJCVJRD4yxsyYGWOM+Vhr6t+p07ln73P23efcmjm/unXvWWvttfdZe6+99oE++uijHAwCJgOLgLXAduAgcAw4C1wAbgC3gQfAU+Al8Bb4AHwGvgI/gd9Af+A38AcYCPwCBgCDgSHAMGAkMBoYB0wApgIzgdnAPKABmA8sBpqAFcAaYCOwBdgF7AeOAKeBS8Bt4DHwAvgAfAPCvlQPMAJoAJqBncAh4CpwH3gFfCK6wDLRD6gHJgGLgXXAduAEcBN4jvNlvTIWWAlsA04Cd4DPRJ+8V4YCc4A1wB7gHPCIaB3ywlhgObANOA3cI/pCeWEUsBTYApwB7hJ9Qa9MAJYAm4DTwEOiL+KVscAiYCNwCnhA9Pm9MgaYD6wHjgP3ib6IV+qAOcBq4AhwF/hB9IW8MhyYBawC9gE3gPdEX8ArQ4GZwErgIHALeEP0RbwyGJgOrAQOADeJvoBXBgFTgRXAYeA68IroC3llADAZWA4cAa4Bz4i+iFf6AxOBZcBR4CrRi3tlCNAILAWOAVeAp0RfxCsDgQagCTgOXAaeEH0Rr9QBU4AlwAngEvCY6It4ZRgwB1gMnAQuAo+IvohX6oFZwCLgFHABeEj0RbwyEpgJLAROA+eBB0RfxCsjgOnAAuAMcA64T/RFvDIcmAbMB84C54i+gFfqgKnAPOAscJboC3hlCDAFmAucA84QfQGvDAYmA3OAs8Bpoi/glYHARGAWcAo4RfQFvDIAmADMBE4CJ4m+gFf6A+OBGcAJ4ATwjeiLeGUQMA2YDhwHjgNfib6IV4YCU4FpwDHgGPCF6It4ZRgwBWgEjgJHgc9EX8QrI4HJQANwBDgCfCL6Il4ZA0wCGoHDwGHgI9EX8cp4YCLQABwCDgEfiL6IV+qBCUADcBA4CHwn+iJeGQWMBxqAA8AB4BvRF/HKcGAcMA7YD+wHvhJ9Ea8MBcYCY4F9wD7gC9EX8cogYAwwBtgL7AU+E30RrwwARgOjgT3AHuAT0RfxSh0wChgF7AZ2Ax+JvohX+gEjgZHALmAX8IHoi3ilDzAcGAHsBHYC74m+iFd6gWHAMGAHsAN4R/RFvNIDDAWGAtuB7cBboi/ilW6gHqgHtgHbgDdEX8QrXcAQYAiwFdgKvCb6Il7pBAYDg4EtwBbgFdEX6aOPPvroI4L/Uf8Iy9Oe0QQAAAAASUVORK5CYII=
EOL

# Crear servicio systemd
cat > ~/pos-system/pos-system.service << 'EOL'
[Unit]
Description=POS System Service
After=network.target

[Service]
ExecStart=/usr/bin/node /home/pi/pos-system/server/index.js
WorkingDirectory=/home/pi/pos-system
StandardOutput=inherit
StandardError=inherit
Restart=always
User=pi

[Install]
WantedBy=multi-user.target
EOL

# Crear script de inicio para modo kiosko
cat > ~/pos-system/start-pos.sh << 'EOL'
#!/bin/bash

# Esperar a que el sistema se inicie completamente
sleep 10

# Verificar si el servidor está en ejecución
while ! curl -s http://localhost:3000 > /dev/null; do
  echo "Esperando a que el servidor se inicie..."
  sleep 2
done

# Iniciar Chromium en modo kiosko
chromium-browser --kiosk --app=http://localhost:3000 --no-first-run --disable-infobars --disable-session-crashed-bubble --disable-features=TranslateUI --noerrdialogs --disable-pinch --overscroll-history-navigation=0
EOL

# Hacer ejecutable el script de inicio
chmod +x ~/pos-system/start-pos.sh

# Configurar inicio automático
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/pos.desktop << 'EOL'
[Desktop Entry]
Type=Application
Name=POS System
Exec=/home/pi/pos-system/start-pos.sh
EOL

# Instalar servicio systemd
sudo cp ~/pos-system/pos-system.service /etc/systemd/system/
sudo systemctl enable pos-system
sudo systemctl start pos-system

# Configurar impresora
echo "Configurando impresora..."
sudo lpadmin -p POS_Printer -E -v usb://Generic/Thermal%20Printer -m drv:///sample.drv/generic.ppd -o PageSize=Custom.58x210mm
sudo lpadmin -d POS_Printer
sudo cupsenable POS_Printer
sudo cupsaccept POS_Printer

# Optimizaciones para Raspberry Pi 3
echo "Aplicando optimizaciones para Raspberry Pi 3..."
sudo bash -c 'cat > /etc/sysctl.d/99-swappiness.conf << EOL
vm.swappiness=10
EOL'

sudo bash -c 'cat > /boot/config.txt << EOL
# Optimizaciones para POS
gpu_mem=128
arm_freq=1200
over_voltage=2
EOL'

# Mensaje final
echo "=== Instalación completada ==="
echo "El sistema POS se ha instalado correctamente."
echo "Reinicia el Raspberry Pi para que todos los cambios surtan efecto:"
echo "sudo reboot"
