const express = require('express');
const app = express();

const PORT = process.env.PORT || 3000;
const APP_NAME = process.env.APP_NAME || 'Express App';

app.get('/', (req, res) => {
  res.send(`
    <html>
      <head><title>${APP_NAME}</title></head>
      <body>
        <h1>Hello from ${APP_NAME}!</h1>
        <p>This is a sample Express.js application running on Appmotel.</p>
        <p>Port: ${PORT}</p>
      </body>
    </html>
  `);
});

app.get('/health', (req, res) => {
  res.json({ status: 'healthy' });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Server running on port ${PORT}`);
});
