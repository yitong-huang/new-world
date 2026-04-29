package newworld.nw

import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity

class MainActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val host = EditText(this).apply { hint = "server host"; setText("10.0.2.2") }
        val user = EditText(this).apply { hint = "username (optional; or use files/nw_auth.json)" }
        val pass = EditText(this).apply { hint = "password (optional)"; inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD }
        val start = Button(this).apply { text = "Start VPN (dev / trust-all TLS)" }
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(host)
            addView(user)
            addView(pass)
            addView(start)
        }
        setContentView(layout)
        start.setOnClickListener {
            val h = host.text.toString().trim()
            pendingHost = h
            pendingUser = user.text.toString().trim()
            pendingPass = pass.text.toString()
            val intent = VpnService.prepare(this)
            if (intent != null) {
                startActivityForResult(intent, REQ_VPN)
            } else {
                startNw(h, user.text.toString().trim(), pass.text.toString())
            }
        }
    }

    private var pendingHost: String? = null
    private var pendingUser: String = ""
    private var pendingPass: String = ""

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_VPN && resultCode == RESULT_OK) {
            if (pendingHost != null) startNw(pendingHost!!, pendingUser, pendingPass)
        } else {
            Toast.makeText(this, "VPN permission denied", Toast.LENGTH_SHORT).show()
        }
    }

    private fun startNw(h: String, u: String, p: String) {
        if (h.isEmpty()) return
        val i = Intent(this, NwVpnService::class.java)
        i.putExtra("host", h)
        i.putExtra("port", 8443)
        i.putExtra("insecure", true)
        if (u.isNotEmpty()) {
            i.putExtra("username", u)
            i.putExtra("password", p)
        }
        startService(i)
        Toast.makeText(this, "Starting…", Toast.LENGTH_SHORT).show()
    }

    companion object {
        private const val REQ_VPN = 1001
    }
}
