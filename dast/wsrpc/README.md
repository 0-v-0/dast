# wsrpc.genapi

TypeScript接口声明生成器

## Usage
```d
import dast.wsrpc.genapi,
std.array;

auto app = appender!string;
ForModules!modules.genAPIDef(app);
```
其中`modules`为模块的`AliasSeq`序列，为模块中所有`@Action`修饰的函数生成对应的ts声明，每个函数只能修饰一次`@Action`

注解格式
```d
@Action:
/// 函数说明
@"返回值说明"@type("自定义返回类型") void func(
	@"参数1说明"int a,
	@"参数2说明"uint[] b,
	@type("自定义参数类型") @"参数3说明" string c = null) {
}
```
对应ts声明：
```ts
/**
 * 函数说明
 * @param a 参数1说明
 * @param b 参数2说明
 * @param c 参数3说明
 * @returns 返回值说明
 */
func(a: number, b: number[], limit?: 自定义参数类型): 自定义返回类型
```
`WSRequest`类型的参数会被忽略

目前函数说明只支持一行，其中函数说明所在行和函数所在行间隔不能超过1行，一般将返回值说明和自定义返回类型放在同一行，若返回值说明有多行，在代码中使用`\n`转义字符代替换行符
可选参数后自动添加`?`

## 默认类型转换规则
1. `typeof(null)`类型，ts中类型为`null`
2. 数字类型转换为`number`，布尔型转换为`boolean`，字符类型转换为`string`
3. 可转换为`const(char)[]`的数组类型，ts中类型为`string`
4. 若参数类型在ts中没有对应类型，则ts中类型为`any`