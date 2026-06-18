const express = require('express');

const app = express();
const port = process.env.PORT || 8080;

app.use(express.json());

app.get('/', (req, res) => {
  res.json({
    service: 'example-demo-app',
    status: 'ok',
    endpoints: ['/', '/health', '/api/users', '/api/users/:id', '/api/echo'],
  });
});

app.get('/health', (req, res) => {
  res.json({ status: 'healthy', uptime: process.uptime() });
});

const users = [
  { id: 1, name: 'Ada Lovelace', role: 'engineer' },
  { id: 2, name: 'Grace Hopper', role: 'admiral' },
  { id: 3, name: 'Alan Turing', role: 'cryptanalyst' },
];

app.get('/api/users', (req, res) => {
  res.json(users);
});

app.get('/api/users/:id', (req, res) => {
  const user = users.find((u) => u.id === Number(req.params.id));
  if (!user) {
    return res.status(404).json({ error: 'user not found' });
  }
  res.json(user);
});

app.post('/api/echo', (req, res) => {
  res.json({ received: req.body });
});

app.listen(port, () => {
  console.log(`example-demo-app listening on port ${port}`);
});
