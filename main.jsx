import React from 'react'
import ReactDOM from 'react-dom/client'
import AvalancheDigitalTwin from './app.jsx' // Ton composant
import './index.css' // Pour mettre le body/html à height: 100%

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <AvalancheDigitalTwin />
  </React.StrictMode>
)