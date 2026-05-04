package com.newworld.nwvpn

import android.Manifest
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.newworld.nwvpn.state.TunnelState
import com.newworld.nwvpn.state.VpnConnectionPhase
import com.newworld.nwvpn.ui.theme.NwVpnTheme
import com.newworld.nwvpn.vpn.NwVpnService

class MainActivity : ComponentActivity() {

    private val notifPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            notifPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        setContent {
            NwVpnTheme {
                val vm: HomeViewModel = viewModel()
                HomeScreen(vm = vm)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HomeScreen(vm: HomeViewModel) {
    val activity = LocalContext.current as ComponentActivity
    val vpnLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        vm.onVpnPermissionResult(result.resultCode == ComponentActivity.RESULT_OK)
    }

    val nodes by vm.nodes.collectAsStateWithLifecycle()
    val selectedHost by vm.selectedHost.collectAsStateWithLifecycle()
    val username by vm.username.collectAsStateWithLifecycle()
    val password by vm.password.collectAsStateWithLifecycle()
    val chinaDirect by vm.chinaDirect.collectAsStateWithLifecycle()
    val phase by TunnelState.phase.collectAsStateWithLifecycle()
    val statusText by TunnelState.statusText.collectAsStateWithLifecycle()
    val lastError by TunnelState.lastError.collectAsStateWithLifecycle()

    var expanded by remember { mutableStateOf(false) }

    val statusColor = when (phase) {
        VpnConnectionPhase.Connected -> Color(0xFF1565C0)
        VpnConnectionPhase.Disconnected -> Color(0xFFC62828)
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    val statusTappable = vm.statusRowTappable()

    Scaffold(
        topBar = {
            TopAppBar(title = { Text("NewWorld VPN") })
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 8.dp),
        ) {
            Text("服务器", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.height(8.dp))
            if (nodes.isEmpty()) {
                Text(
                    "未加载节点列表（请确认已打包 assets/servers）",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                ExposedDropdownMenuBox(
                    expanded = expanded,
                    onExpandedChange = { expanded = !expanded },
                ) {
                    OutlinedTextField(
                        modifier = Modifier
                            .menuAnchor()
                            .fillMaxWidth(),
                        readOnly = true,
                        value = nodes.firstOrNull { it.host == selectedHost }?.displayName ?: selectedHost,
                        onValueChange = {},
                        label = { Text("节点") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
                    )
                    ExposedDropdownMenu(
                        expanded = expanded,
                        onDismissRequest = { expanded = false },
                    ) {
                        nodes.forEach { node ->
                            DropdownMenuItem(
                                text = { Text(node.displayName) },
                                onClick = {
                                    vm.selectHost(node.host)
                                    expanded = false
                                },
                            )
                        }
                    }
                }
            }

            Spacer(Modifier.height(20.dp))
            Text("认证（可选）", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = username,
                onValueChange = vm::setUsername,
                label = { Text("用户名") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = password,
                onValueChange = vm::setPassword,
                label = { Text("密码") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth(),
            )

            Spacer(Modifier.height(20.dp))
            Text("分流", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.height(8.dp))
            Column {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("仅墙外走隧道（国内直连）", modifier = Modifier.weight(1f))
                    Switch(checked = chinaDirect, onCheckedChange = vm::setChinaDirect)
                }
                Text(
                    "开启后会使用扩展内置的 china_ipv4/extra_direct_ipv4 规则。若连接失败，可先关闭此项做排查。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            Spacer(Modifier.height(20.dp))
            Text("状态", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.height(12.dp))
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 48.dp)
                    .clickable(enabled = statusTappable) {
                        if (!vm.tryConsumeStatusTap()) return@clickable
                        when (TunnelState.phase.value) {
                            VpnConnectionPhase.Connected -> {
                                NwVpnService.stopTunnel(activity)
                            }
                            VpnConnectionPhase.Disconnected -> {
                                val prep = VpnService.prepare(activity)
                                if (prep != null) {
                                    vpnLauncher.launch(prep)
                                } else {
                                    vm.performConnect()
                                }
                            }
                            else -> Unit
                        }
                    }
                    .padding(vertical = 8.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    text = statusText,
                    fontSize = 22.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = statusColor,
                )
                if (!lastError.isNullOrEmpty()) {
                    Spacer(Modifier.height(12.dp))
                    HorizontalDivider()
                    Spacer(Modifier.height(10.dp))
                    Text(
                        text = lastError!!,
                        color = Color(0xFFC62828),
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
    }
}
