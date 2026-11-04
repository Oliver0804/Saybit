// Pipeline session 世代計數（審查 C1）。每次開錄 / 取消 / 重新生成都 bump()，
// 所有 await 之後與回呼內比對 isCurrent(gen)，不符代表已被作廢就直接收手。
// bump() 同時 abort 掛在目前世代上的 AbortController，讓在飛的 HTTP 真的中斷。

export class SessionGeneration {
  private value = 0;
  private controller: AbortController | null = null;

  get current(): number {
    return this.value;
  }

  /// 作廢目前世代（含中斷請求），回傳新世代
  bump(): number {
    this.value += 1;
    if (this.controller) {
      this.controller.abort();
      this.controller = null;
    }
    return this.value;
  }

  isCurrent(gen: number): boolean {
    return gen === this.value;
  }

  /// 綁定到 gen 的存活檢查
  guard(gen: number): () => boolean {
    return () => gen === this.value;
  }

  /// 為目前世代建立 AbortController（取代舊的）；下次 bump() 會 abort 它
  newController(): AbortController {
    this.controller?.abort();
    const c = new AbortController();
    this.controller = c;
    return c;
  }

  /// 工作正常結束時解除綁定（不 abort）
  release(controller: AbortController): void {
    if (this.controller === controller) this.controller = null;
  }
}
