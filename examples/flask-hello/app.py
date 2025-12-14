#!/usr/bin/env python3

import os
from flask import Flask

app = Flask(__name__)

@app.route('/')
def hello():
    app_name = os.environ.get('APP_NAME', 'Flask App')
    return f'''
    <html>
        <head><title>{app_name}</title></head>
        <body>
            <h1>Hello from {app_name}!</h1>
            <p>This is a sample Flask application running on Appmotel.</p>
            <p>Port: {os.environ.get('PORT', 'unknown')}</p>
        </body>
    </html>
    '''

@app.route('/health')
def health():
    return {'status': 'healthy'}, 200

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 5000))
    app.run(host='0.0.0.0', port=port)
