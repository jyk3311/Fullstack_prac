import { useEffect, useState } from 'react'
import './App.css'

function App() {
  const [users, setUsers] = useState([])
  const [error, setError] = useState(null)

  useEffect(() => {
    fetch('/api/users')
      .then((response) => {
        if (!response.ok) {
          throw new Error(`API error: ${response.status}`)
        }
        return response.json()
      })
      .then((data) => setUsers(data))
      .catch((err) => setError(err.message))
  }, [])

  return (
    <main style={{ padding: '40px', fontFamily: 'Arial, sans-serif' }}>
      <h1>Fullstack Pipeline Test</h1>

      <h2>Users</h2>

      {error && <p style={{ color: 'red' }}>{error}</p>}

      <ul>
        {users.map((user) => (
          <li key={user.id}>
            {user.username} / {user.email}
          </li>
        ))}
      </ul>
    </main>
  )
}

export default App