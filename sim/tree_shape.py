"""感染树形状蒙特卡洛模拟（落地可行性评估 §3.2 / GDB V1.1 §8.7）。

模型：N 名参与者，追击能力服从对数正态分布（sigma 越大技术差距越大）；
每次感染按能力加权选出一名感染者作为扑咬者，受害者从人类中随机选取。
统计感染比例达到 infect_frac 时：
  - P(HUB>=4)：是否存在 branchImpact >= 4 的可治愈节点
  - bestCut：最优一针切掉的感染者比例
  - rootDirect：根节点直接感染的占比
未包含空间位置、治愈与重连的动态过程，只用于判断方向。

用法：python3 sim/tree_shape.py
"""

import random
import statistics as st


def run(n, seeds, sigma, root_is_best, infect_frac, trials=4000):
    hub_rate = 0
    best_cut = []
    root_child_share = []
    for _ in range(trials):
        skill = [random.lognormvariate(0, sigma) for _ in range(n)]
        order = sorted(range(n), key=lambda i: -skill[i])
        roots = order[:seeds] if root_is_best else random.sample(range(n), seeds)
        parent = {r: None for r in roots}
        humans = set(range(n)) - set(roots)
        target = int(n * infect_frac)
        while len(parent) < target and humans:
            infected = list(parent)
            biter = random.choices(infected, [skill[i] for i in infected])[0]
            victim = random.choice(list(humans))
            humans.remove(victim)
            parent[victim] = biter

        children = {}
        for child, p in parent.items():
            if p is not None:
                children.setdefault(p, []).append(child)

        def size(node):
            return 1 + sum(size(c) for c in children.get(node, []))

        curable = [node for node in parent if parent[node] is not None]
        best = max((size(node) for node in curable), default=0)
        best_cut.append(best / len(parent))
        hub_rate += best >= 4
        root_children = sum(len(children.get(r, [])) for r in roots)
        root_child_share.append(root_children / max(1, len(curable)))
    return hub_rate / trials, st.mean(best_cut), st.mean(root_child_share)


def main():
    print("N seeds sigma rootBest infFrac | P(HUB>=4) | bestCut | rootDirect")
    cases = [
        (8, 1, 0.5),
        (8, 1, 0.75),
        (12, 1, 0.75),
        (16, 2, 0.5),
        (24, 2, 0.5),
    ]
    for n, seeds, frac in cases:
        for sigma in (0.8, 1.5):
            for root_is_best in (False, True):
                hub, cut, direct = run(n, seeds, sigma, root_is_best, frac, trials=3000)
                print(f"{n:2d} {seeds} {sigma:.1f} {str(root_is_best):5s} {frac:.2f} | {hub:.2f} | {cut:.2f} | {direct:.2f}")


if __name__ == "__main__":
    main()
